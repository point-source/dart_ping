import 'dart:async';

import 'package:dart_ping/src/dart_ping_base.dart';
import 'package:flutter/services.dart';
import 'package:dart_ping/src/base_ping.dart';
import 'package:dart_ping/src/models/ping_data.dart';
import 'package:dart_ping/src/models/ping_error.dart';
import 'package:dart_ping/src/models/ping_response.dart';
import 'package:dart_ping/src/models/ping_summary.dart';

class PingiOS extends BasePing implements Ping {
  PingiOS(String host, int count, double interval, double timeout, bool ipv6)
      : super(host, count, interval, timeout, ipv6);

  static const _channelName = 'dart_ping';
  static const _methodCh = MethodChannel('$_channelName/method');
  static const _eventCh = EventChannel('$_channelName/event');

  @override
  Future<void> onListen() async {
    await _methodCh.invokeMethod('start', {
      'host': host,
      'count': count,
      'interval': interval,
      'timeout': timeout,
      'ipv6': ipv6,
    });
    subscription = _eventCh
        .receiveBroadcastStream()
        .transform<PingData>(_iosTransformer)
        .listen(controller.add);
  }

  @override
  void stop() {
    _methodCh.invokeMethod('stop').then((_) {
      super.stop();
    });
  }

  /// StreamTransformer for iOS response from the event channel.
  static final StreamTransformer<dynamic, PingData> _iosTransformer =
      StreamTransformer.fromHandlers(
    handleData: (data, sink) {
      var err;
      switch (data['error']) {
        case 'RequestTimedOut':
          err = PingError.RequestTimedOut;
          break;
        case 'UnknownHost':
          err = PingError.UnknownHost;
          break;
      }
      var response;
      if (data['seq'] != null) {
        response = PingResponse(
          seq: data['seq'],
          ip: data['ip'],
          ttl: data['ttl'],
          time: Duration(
              microseconds:
                  (data['time'] * Duration.microsecondsPerSecond).floor()),
        );
      }
      var summary;
      if (data['received'] != null) {
        summary = PingSummary(
          received: data['received'],
          transmitted: data['transmitted'],
          time: Duration(
              microseconds:
                  (data['time'] * Duration.microsecondsPerSecond).floor()),
        );
      }
      sink.add(
        PingData(
          response: response,
          summary: summary,
          error: err,
        ),
      );
    },
  );
}
