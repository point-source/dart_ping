import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:dart_ping/src/address_family.dart';
import 'package:dart_ping/src/ip_version.dart';
import 'package:dart_ping/src/models/ping_event.dart';
import 'package:dart_ping/src/models/ping_parser.dart';
import 'package:dart_ping/src/ping_interface.dart';
import 'package:dart_ping/src/ping/ios/dart_ping_bindings.dart';
import 'package:dart_ping/src/ping/ios/ios_event_mapper.dart';

/// The FFI-backed iOS [Ping] implementation.
///
/// Each `IosPing` instance owns its OWN native run handle, its OWN
/// [NativeCallable], and its OWN [NativeEventStatsMapper]. There is NO shared
/// broadcast stream, NO run id, and NO id-demultiplexing: the whole channel
/// machinery the old `dart_ping_ios` bridge needed is gone. Because all run
/// state is instance-local (no `static` mutable state at all), concurrent pings
/// to distinct hosts cannot cross-contaminate — isolation is by construction
/// (§spec:concurrent-isolation). The on-device manual acceptance path verifies
/// true concurrent-ICMP isolation end to end.
///
/// Threading model (§spec:ios-background-isolate): the native engine invokes its
/// per-event callback on a BACKGROUND queue. We bridge that to Dart with a
/// `NativeCallable.listener`, which delivers each native invocation to THIS
/// isolate's event loop rather than running it inline on the native thread. That
/// is what lets an iOS ping run be created and consumed from ANY isolate (it
/// fixes #48); the native C call returns immediately and the Dart handler runs
/// later on this isolate.
///
/// Round-trip precision is preserved across the FFI seam: the native engine
/// reports each RTT (and the session duration) in MICROSECONDS, and that
/// magnitude flows through unrounded into the [PingEvent]s
/// (§spec:stats-precision). Round-trip statistics are computed by the shared
/// core [RoundTripStatsAccumulator] (via [NativeEventStatsMapper]) — the same
/// type and math the subprocess platforms use — so iOS stats match core by
/// construction (§spec:stats-ios).
class IosPing implements Ping {
  /// Creates an iOS ping bound to [host], mirroring the field set the channel
  /// bridge carried. The address-family guard runs in the constructor — exactly
  /// as every other platform does — so a literal IP whose family contradicts
  /// [ipVersion] fails fast with the identical [ArgumentError], regardless of
  /// whether the instance is ever listened to.
  IosPing(
    this._host,
    this._count,
    this._interval,
    this._timeout,
    this._ttl,
    this._ipVersion,
    this._nat64Synthesis,
  ) {
    validateAddressFamily(_host, _ipVersion);
  }

  /// Adapter matching [Ping.iosFactory]'s signature so the registrar (WS4) can
  /// wire iOS support with a single assignment. `parser` and `encoding` are
  /// accepted for signature parity but ignored — the native engine emits typed
  /// events directly, so there is nothing to parse or decode (exactly as the
  /// old `DartPingIOS._init` did).
  // ignore: long-parameter-list
  static IosPing fromFactory(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    IpVersion ipVersion,
    PingParser? parser,
    Encoding encoding,
    bool nat64Synthesis,
  ) =>
      IosPing(host, count, interval, timeout, ttl, ipVersion, nat64Synthesis);

  final String _host;
  final int? _count;
  final int _interval;
  final int _timeout;
  final int _ttl;
  final IpVersion _ipVersion;
  final bool _nat64Synthesis;

  // Per-instance run state (§spec:concurrent-isolation). None of this is static.
  StreamController<PingEvent>? _controller;
  NativeCallable<DartPingEventCallbackNative>? _callable;
  NativeEventStatsMapper? _statsMapper;
  Pointer<Void> _handle = nullptr;

  /// Set when the subscription is cancelled. A cancelled run drops the terminal
  /// summary (the [Ping] contract), but the callable must outlive the engine's
  /// post-stop summary callback, so teardown is still driven by that final
  /// native invocation.
  bool _cancelled = false;

  /// Guards [_teardown] so it runs exactly once.
  bool _tornDown = false;

  /// Guards the native `dart_ping_stop` so it runs exactly once, no matter how
  /// many lifecycle paths request it (stop(), cancel, natural completion).
  bool _stopped = false;

  /// Unused on iOS and should not be called.
  @override
  PingParser get parser => throw UnimplementedError();

  /// Unused on iOS and should not be called.
  @override
  set parser(PingParser parser) => throw UnimplementedError();

  @override
  String get command =>
      'Ping on iOS is provided by a native Swift ICMP engine';

  @override
  Stream<PingEvent> get stream {
    final controller = _controller ??= StreamController<PingEvent>(
      onListen: _onListen,
      onCancel: _onCancel,
    );

    return controller.stream;
  }

  @override
  Future<bool> stop() async {
    // Stop the engine if a run is active; it emits a terminal summary on its
    // background queue, which [_handleNativeEvent] forwards before closing the
    // stream (the [Ping] contract — stop() keeps the summary).
    _stopNative();

    return true;
  }

  void _onListen() {
    _statsMapper = NativeEventStatsMapper();

    // `.listener` delivers the background-thread native callback to THIS
    // isolate's event loop, which is what makes iOS ping work from any isolate
    // (#48). Keep a reference so it is not GC'd and so it can be closed at
    // teardown.
    _callable =
        NativeCallable<DartPingEventCallbackNative>.listener(_handleNativeEvent);

    final hostPtr = _host.toNativeUtf8();
    final family =
        _ipVersion == IpVersion.ipv6 ? DartPingFamily.v6 : DartPingFamily.v4;

    _handle = dartPingStart(
      hostPtr,
      _count ?? -1,
      _interval.toDouble(),
      _timeout.toDouble(),
      _ttl,
      family,
      _nat64Synthesis,
      _callable!.nativeFunction,
      nullptr,
    );

    // The shim copies the host into the Swift Config, so the C string is no
    // longer needed once start has returned.
    malloc.free(hostPtr);

    if (_handle == nullptr) {
      // C returns null only on a null host/callback — a programming error.
      // Surface a graceful error event and tear down rather than hanging.
      _controller?.addError(
        StateError('Failed to start iOS ping engine for host "$_host"'),
      );
      _teardown();
    }
  }

  /// Runs on this isolate's event loop (the native C call has already returned).
  void _handleNativeEvent(Pointer<Void> ctx, Pointer<DartPingEvent> evPtr) {
    // 1. Copy EVERYTHING we need out of the heap-owned struct now.
    final dto = _decodeEvent(evPtr.ref);

    // 2. The event is heap-owned by us (WS1's lifetime contract); free it
    //    exactly once, after copying.
    freeNativeEvent(evPtr);

    // 3. Map to a sealed PingEvent carrying the running stats snapshot, forward
    //    it, and tear down once the terminal summary has been delivered.
    final event = _statsMapper!.map(dto);
    _forward(event);
    if (event is PingSummary) _teardown();
  }

  /// Forwards a mapped event to the stream, unless the run was cancelled (cancel
  /// drops events — including the terminal summary — per the [Ping] contract) or
  /// the controller is already closed.
  void _forward(PingEvent event) {
    if (_cancelled) return;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.add(event);
    }
  }

  /// Decodes a delivered [DartPingEvent] into the FFI-free [NativePingEvent]
  /// DTO. Reads only the fields valid for the active [DartPingEvent.kind] and
  /// honors the `has*` presence flags.
  NativePingEvent _decodeEvent(DartPingEvent ev) {
    final kind = _eventKind(ev.kind);
    switch (kind) {
      case NativeEventKind.response:
        return NativePingEvent(
          kind: kind,
          seq: ev.hasSeq ? ev.seq : null,
          ttl: ev.hasTtl ? ev.ttl : null,
          timeMicros: ev.timeMicros,
          ip: ev.hasIp ? ev.ip.toDartString() : null,
        );
      case NativeEventKind.error:
        return NativePingEvent(
          kind: kind,
          seq: ev.hasSeq ? ev.seq : null,
          ip: ev.hasIp ? ev.ip.toDartString() : null,
          errorKind: _errorKind(ev.errorKind),
        );
      case NativeEventKind.summary:
        final errors = <NativeErrorKind>[];
        if (ev.errorsLen > 0 && ev.errors != nullptr) {
          final codes = ev.errors.asTypedList(ev.errorsLen);
          for (final code in codes) {
            errors.add(_errorKind(code));
          }
        }

        return NativePingEvent(
          kind: kind,
          timeMicros: ev.timeMicros,
          transmitted: ev.transmitted,
          received: ev.received,
          errors: errors,
        );
    }
  }

  static NativeEventKind _eventKind(int kind) {
    switch (kind) {
      case DartPingEventKind.response:
        return NativeEventKind.response;
      case DartPingEventKind.error:
        return NativeEventKind.error;
      case DartPingEventKind.summary:
        return NativeEventKind.summary;
      default:
        // The C ABI only emits the three known kinds; treat anything else as a
        // summary-shaped terminal would be wrong, so map to an error event the
        // mapper can render. This is unreachable in practice.
        return NativeEventKind.error;
    }
  }

  static NativeErrorKind _errorKind(int kind) {
    switch (kind) {
      case DartPingErrorKind.requestTimedOut:
        return NativeErrorKind.requestTimedOut;
      case DartPingErrorKind.timeToLiveExceeded:
        return NativeErrorKind.timeToLiveExceeded;
      case DartPingErrorKind.noReply:
        return NativeErrorKind.noReply;
      case DartPingErrorKind.unknownHost:
        return NativeErrorKind.unknownHost;
      case DartPingErrorKind.noRoute:
        return NativeErrorKind.noRoute;
      default:
        return NativeErrorKind.unknown;
    }
  }

  void _onCancel() {
    _cancelled = true;
    // Stop the native engine so an unbounded run (count == null) does not leak
    // its engine/socket. Do NOT close the NativeCallable here: the engine still
    // emits a final summary on its background queue after stop(); let
    // [_handleNativeEvent] observe that terminal summary and run [_teardown], so
    // the callable always outlives the last native invocation. Closing it early
    // would crash on a post-stop callback (see the lifecycle caveat in
    // dart_ping_ffi.h).
    _stopNative();
  }

  /// Stops the native run and releases its run box, exactly once. `dart_ping_stop`
  /// is what frees the engine box even on natural completion, and it is safe to
  /// call on an already-finished/already-stopped engine; the [_stopped] guard
  /// keeps the multiple lifecycle paths (stop(), cancel, teardown) to one call.
  void _stopNative() {
    if (_stopped) return;
    _stopped = true;
    if (_handle != nullptr) {
      dartPingStop(_handle);
      _handle = nullptr;
    }
  }

  /// Idempotent teardown. Releases the native run box, closes the stream, and
  /// closes the [NativeCallable]. Reached via stop(), cancel, natural
  /// completion, or a failed start — exactly once.
  void _teardown() {
    if (_tornDown) return;
    _tornDown = true;

    // On NATURAL completion the engine emits the terminal summary but only
    // `dart_ping_stop` releases the native run box, so stop here too (a no-op if
    // stop()/cancel already did).
    _stopNative();

    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.close();
    }

    // Safe now: the terminal summary was the last native invocation.
    _callable?.close();
    _callable = null;
  }
}
