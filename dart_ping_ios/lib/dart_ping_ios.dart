import 'dart:async';
import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:flutter/services.dart';

import 'src/ping_event_mapper.dart';

/// iOS implementation of the [Ping] interface.
///
/// Drives a native Swift ICMP engine over a Flutter method/event channel,
/// mapping native results back onto the cross-platform [PingData] models.
class DartPingIOS implements Ping {
  DartPingIOS(
    this._host,
    this._count,
    this._interval,
    this._timeout,
    this._ttl,
    this._ipv6,
  ) : _id = _generateId();

  /// Installs the iOS factory on [Ping.iosFactory]. Documented entry point
  /// for enabling iOS support (§spec:public-api-stability).
  static void register() {
    Ping.iosFactory = _init;
  }

  static DartPingIOS _init(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    bool ipv6,
    PingParser? parser,
    Encoding encoding,
  ) {
    return DartPingIOS(host, count, interval, timeout, ttl, ipv6);
  }

  /// MethodChannel used to start/stop native ping runs.
  static const MethodChannel _method = MethodChannel('dart_ping_ios');

  /// Single shared broadcast stream of native events. Sharing one stream
  /// means native's `onListen` fires once across all instances; each run is
  /// demultiplexed by matching its `id`.
  static final Stream<dynamic> _events =
      const EventChannel('dart_ping_ios/events').receiveBroadcastStream();

  /// Monotonic counter combined with a timestamp to produce a unique run id
  /// without adding a package dependency.
  static int _counter = 0;

  static String _generateId() {
    _counter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_counter';
  }

  final String _host;
  final int? _count;
  final int _interval;
  final int _timeout;
  final int _ttl;
  final bool _ipv6;

  /// Unique identifier for this run, used to demultiplex shared events.
  final String _id;

  StreamController<PingData>? _controller;
  StreamSubscription<dynamic>? _eventSub;

  /// Unused on iOS and should not be called
  @override
  PingParser get parser => throw UnimplementedError();

  /// Unused on iOS and should not be called
  @override
  set parser(PingParser parser) => throw UnimplementedError();

  @override
  String get command => 'Ping on iOS is provided by a native Swift ICMP engine';

  /// Stream of [PingData] events. One for each response, error, or summary.
  ///
  /// On listen, subscribes to the shared native event stream (filtered to
  /// this run's id) and then starts the native run. The stream closes once
  /// the terminal `summary` event has been forwarded.
  @override
  Stream<PingData> get stream {
    _controller ??= StreamController<PingData>(
      onListen: _onListen,
      onCancel: _onCancel,
    );

    return _controller!.stream;
  }

  void _onListen() {
    final controller = _controller;
    if (controller == null) return;

    _eventSub = _events
        .where((event) => event is Map && event['id'] == _id)
        .listen((event) {
      final data = mapNativeEvent(event as Map);
      if (data == null) return;

      if (!controller.isClosed) {
        controller.add(data);
      }

      // The summary is terminal: the run is done once it has been delivered.
      if (data.summary != null && !controller.isClosed) {
        controller.close();
      }
    });

    _method.invokeMethod('start', {
      'id': _id,
      'host': _host,
      'count': _count,
      'interval': _interval,
      'timeout': _timeout,
      'ttl': _ttl,
      'ipv6': _ipv6,
    });
  }

  Future<void> _onCancel() async {
    // Cancelling the subscription means "drop the summary" per the Ping
    // contract: cancel our event subscription first so the forthcoming
    // summary is not delivered. We STILL tell native to stop, otherwise an
    // unbounded run (count == null) would leak its socket/timer/engine and
    // keep transmitting forever. The dropped summary is the contract; the
    // leaked engine was a bug.
    await _eventSub?.cancel();
    _eventSub = null;
    await _method.invokeMethod('stop', {'id': _id});
  }

  /// Stop the currently running ping.
  ///
  /// Native emits the final `summary` in response, which the stream forwards
  /// before closing, so the summary is still delivered (§spec:ios-ping-behavior).
  @override
  Future<bool> stop() async {
    await _method.invokeMethod('stop', {'id': _id});

    return true;
  }
}
