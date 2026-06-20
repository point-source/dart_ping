import 'dart:async';
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
  final String _host;

  final int? _count;
  final int _interval;
  final int _timeout;
  final int _ttl;
  final IpVersion _ipVersion;
  final bool
  _nat64Synthesis; // Per-instance run state (§spec:concurrent-isolation). None of this is static.
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

  @override
  String get command => 'Ping on iOS is provided by a native Swift ICMP engine';

  @override
  Stream<PingEvent> get stream {
    final controller = _controller ??= StreamController<PingEvent>(
      onListen: _onListen,
      onCancel: _onCancel,
    );

    return controller.stream;
  }

  /// Unused on iOS and should not be called.
  @override
  set parser(PingParser value) => throw UnimplementedError();

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
    _callable = NativeCallable<DartPingEventCallbackNative>.listener(
      _handleNativeEvent,
    );

    final hostPtr = _host.toNativeUtf8();
    final family = _ipVersion == .ipv6 ? DartPingFamily.v6 : DartPingFamily.v4;

    try {
      _handle = dartPingStart(
        hostPtr,
        _count ?? -1,
        _interval.toDouble(),
        _timeout.toDouble(),
        _ttl,
        family,
        _nat64Synthesis,
        // _callable is created just above, before this native start call.
        // ignore: avoid-non-null-assertion
        _callable!.nativeFunction,
        nullptr,
      );
    } catch (error, stack) {
      // dartPingStart only throws if the native asset failed to link (a non-iOS
      // / mis-built target). Surface the error and release the callable instead
      // of leaking the trampoline; the host string is freed in `finally`.
      _controller?.addError(error, stack);
      _teardown();

      return;
    } finally {
      // The shim copies the host into the Swift Config, so the C string is no
      // longer needed once start has returned (or thrown).
      malloc.free(hostPtr);
    }

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
    // Read the kind discriminator from the raw struct BEFORE the fallible decode
    // so the terminal summary ALWAYS drives teardown — even if decoding or
    // mapping a (malformed) event throws. Otherwise a throw on a terminal event
    // would skip teardown and leave the consumer hanging.
    final isSummary = evPtr.ref.kind == DartPingEventKind.summary;

    try {
      // Copy EVERYTHING we need out of the heap-owned struct, then free it
      // exactly once. The event is heap-owned by us (the lifetime contract), so
      // the free is in a `finally`: a decode failure (e.g. a malformed IP
      // string) must never leak the native payload.
      final NativePingEvent dto;
      try {
        dto = _decodeEvent(evPtr.ref);
      } finally {
        freeNativeEvent(evPtr);
      }

      // Map to a sealed PingEvent carrying the running stats snapshot and forward.
      // _statsMapper is initialized in the constructor, before any event fires.
      // ignore: avoid-non-null-assertion
      _forward(_statsMapper!.map(dto));
    } catch (error, stack) {
      // A malformed event must not escape as an unhandled async error (this runs
      // on a NativeCallable.listener callback) or skip teardown; surface it on
      // the stream's error channel that consumers already handle.
      final controller = _controller;
      if (!_cancelled && controller != null && !controller.isClosed) {
        controller.addError(error, stack);
      }
    } finally {
      // Tear down once the terminal summary has been seen — guaranteed even if
      // the decode/map/forward above threw, so a malformed terminal event can
      // never hang the consumer.
      if (isSummary) _teardown();
    }
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
      case .response:
        return NativePingEvent(
          kind: kind,
          seq: ev.hasSeq ? ev.seq : null,
          ttl: ev.hasTtl ? ev.ttl : null,
          timeMicros: ev.timeMicros,
          ip: ev.hasIp ? ev.ip.toDartString() : null,
        );

      case .error:
        return NativePingEvent(
          kind: kind,
          seq: ev.hasSeq ? ev.seq : null,
          ip: ev.hasIp ? ev.ip.toDartString() : null,
          errorKind: _errorKind(ev.errorKind),
        );

      case .summary:
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
        return .response;

      case DartPingEventKind.error:
        return .error;

      case DartPingEventKind.summary:
        return .summary;

      // The `default` deliberately shares `.error` with the error case but is a
      // distinct, documented unreachable fallback — keep them separate.
      // ignore: no-equal-switch-case
      default:
        // The C ABI only emits the three known kinds; treat anything else as a
        // summary-shaped terminal would be wrong, so map to an error event the
        // mapper can render. This is unreachable in practice.
        return .error;
    }
  }

  static NativeErrorKind _errorKind(int kind) {
    switch (kind) {
      case DartPingErrorKind.requestTimedOut:
        return .requestTimedOut;

      case DartPingErrorKind.timeToLiveExceeded:
        return .timeToLiveExceeded;

      case DartPingErrorKind.noReply:
        return .noReply;

      case DartPingErrorKind.unknownHost:
        return .unknownHost;

      case DartPingErrorKind.noRoute:
        return .noRoute;

      default:
        return .unknown;
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
      // Fire-and-forget close from synchronous teardown.
      // ignore: avoid-ignoring-return-values
      controller.close();
    }

    // Safe now: the terminal summary was the last native invocation.
    _callable?.close();
    _callable = null;
  }
}
