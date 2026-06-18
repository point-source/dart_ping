import 'dart:async';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// iOS half of §spec:concurrent-isolation (the cross-platform sibling of
/// `dart_ping/test/concurrent_isolation_test.dart`).
///
/// Unlike the core subprocess path (one OS process per run, no shared state),
/// the iOS bridge `DartPingIOS` shares a SINGLE static broadcast
/// `EventChannel` (`dart_ping_ios/events`) across ALL `Ping` instances. Each
/// run demultiplexes the shared stream by a unique per-run `id` via a
/// `.where((e) => e['id'] == _id)` filter in `_onListen`. Isolation rests
/// ENTIRELY on that id-demux being correct.
///
/// This is an OFFLINE test: the method channel is mocked to capture
/// `start`/`stop` calls, and native events are injected onto the shared event
/// channel by hand. No network, no device. It overlaps TWO concurrent runs to
/// distinct hosts with INTERLEAVED, distinctly-id'd events and asserts no
/// event bleeds between runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'dart_ping_ios';
  const eventChannelName = 'dart_ping_ios/events';
  const codec = StandardMethodCodec();

  /// Hard ceiling for every awaited completion. A hung/never-closing stream
  /// would otherwise block the whole suite; the timeout converts it into a
  /// deterministic failure instead. Mirrors the core analogue's `_hardTimeout`.
  const hardTimeout = Duration(seconds: 5);

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> methodCalls;

  /// Pushes a native event onto the shared EventChannel, as the Swift side
  /// would. Only delivered once a [DartPingIOS] stream has a listener.
  void emitNativeEvent(Object? event) {
    messenger.handlePlatformMessage(
      eventChannelName,
      codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  setUp(() {
    methodCalls = [];
    // Capture start/stop invocations on the method channel.
    messenger.setMockMethodCallHandler(
      const MethodChannel(methodChannelName),
      (call) async {
        methodCalls.add(call);
        return null;
      },
    );
    // The EventChannel performs a listen/cancel handshake over its own
    // (event-named) method channel; acknowledge it so the broadcast stream
    // activates.
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      (call) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(methodChannelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      null,
    );
  });

  /// One run's canned, distinct native input plus the values it should yield.
  ///
  /// Builds the native event Maps lazily once the run's `id` has been recovered
  /// from its captured `start` MethodCall, so the same fixture can stamp every
  /// event with the correct id.
  group('concurrent-isolation (§spec:concurrent-isolation)', () {
    /// Recovers a run's `id` from the shared methodCalls list by matching on
    /// the `host` argument of its `start` call. The two starts both land in the
    /// same list, so they MUST be distinguished by host — id ordering is never
    /// assumed.
    String idForHost(String host) {
      final start = methodCalls.firstWhere(
        (c) =>
            c.method == 'start' &&
            (c.arguments as Map)['host'] == host,
        orElse: () => throw StateError('no start captured for host $host'),
      );
      return (start.arguments as Map)['id'] as String;
    }

    test(
        'two concurrent runs over the shared event channel stay fully isolated',
        () async {
      // Run A -> a.example: distinct seq/ttl/time/ip, AND carries ONE error
      // (a requestTimedOut on seq=2). Its summary therefore records that error.
      final pingA = DartPingIOS('a.example', 2, 1, 5, 64, false);
      final receivedA = <PingData>[];
      final doneA = Completer<void>();
      pingA.stream.listen(receivedA.add, onDone: doneA.complete);

      // Run B -> b.example: deliberately DIFFERENT ttl/time/ip so any swap or
      // bleed from A is detectable. Run B has NO error, so its summary's error
      // list must stay empty — any error-list bleed from A is detectable.
      final pingB = DartPingIOS('b.example', 2, 1, 5, 53, false);
      final receivedB = <PingData>[];
      final doneB = Completer<void>();
      pingB.stream.listen(receivedB.add, onDone: doneB.complete);

      // Pump so both onListen handlers run and both `start` calls land.
      await pumpEventQueue();

      final idA = idForHost('a.example');
      final idB = idForHost('b.example');
      expect(idA, isNot(idB), reason: 'each run must have a distinct id');

      // INTERLEAVE the two runs' events through the single shared broadcast
      // stream: A-resp(1), B-resp(1), A-error, B-resp(2), A-summary, B-summary.
      // Each instance's `.where(id == _id)` filter must isolate its own.
      emitNativeEvent({
        'id': idA,
        'type': 'response',
        'seq': 1,
        'ttl': 57,
        'time': 170,
        'ip': '154.16.146.45',
      });
      emitNativeEvent({
        'id': idB,
        'type': 'response',
        'seq': 1,
        'ttl': 53,
        'time': 236,
        'ip': '187.188.169.169',
      });
      // A's timeout on seq=2: a combined response (seq only) + error.
      emitNativeEvent({
        'id': idA,
        'type': 'error',
        'error': 'Request Timed Out',
        'seq': 2,
      });
      emitNativeEvent({
        'id': idB,
        'type': 'response',
        'seq': 2,
        'ttl': 53,
        'time': 240,
        'ip': '187.188.169.169',
      });
      // Terminal summaries (each closes its OWN controller).
      emitNativeEvent({
        'id': idA,
        'type': 'summary',
        'transmitted': 2,
        'received': 1,
        'time': 1001,
        'errors': [
          {'error': 'Request Timed Out', 'message': null},
        ],
      });
      emitNativeEvent({
        'id': idB,
        'type': 'summary',
        'transmitted': 2,
        'received': 2,
        'time': 1002,
        'errors': <dynamic>[],
      });

      // Await BOTH closes under a hard timeout: a missed close (e.g. a summary
      // delivered to the wrong run, or never delivered) becomes a deterministic
      // failure rather than a hang.
      await Future.wait([doneA.future, doneB.future]).timeout(
        hardTimeout,
        onTimeout: () =>
            fail('a concurrent stream did not close within $hardTimeout'),
      );

      // --- Run A reflects ONLY its own id's events ---
      final responsesA = receivedA
          .where((d) => d.response != null)
          .map((d) => d.response!)
          .toList();
      expect(
        responsesA,
        const [
          PingResponse(
            seq: 1,
            ttl: 57,
            time: Duration(milliseconds: 170),
            ip: '154.16.146.45',
          ),
          // The timeout yields a response (seq only) paired with an error.
          PingResponse(seq: 2),
        ],
        reason: 'a.example responses (seq/ttl/time/ip) must be its own, never '
            "b.example's",
      );
      final summariesA =
          receivedA.where((d) => d.summary != null).map((d) => d.summary!);
      expect(summariesA, hasLength(1),
          reason: 'a.example must emit exactly one summary');
      final summaryA = summariesA.single;
      expect(summaryA.transmitted, 2);
      expect(summaryA.received, 1);
      expect(summaryA.time, const Duration(milliseconds: 1001));
      expect(
        summaryA.errors.map((e) => e.error).toList(),
        const [ErrorType.requestTimedOut],
        reason: 'a.example summary carries only its own error',
      );

      // --- Run B reflects ONLY its own id's events ---
      final responsesB = receivedB
          .where((d) => d.response != null)
          .map((d) => d.response!)
          .toList();
      expect(
        responsesB,
        const [
          PingResponse(
            seq: 1,
            ttl: 53,
            time: Duration(milliseconds: 236),
            ip: '187.188.169.169',
          ),
          PingResponse(
            seq: 2,
            ttl: 53,
            time: Duration(milliseconds: 240),
            ip: '187.188.169.169',
          ),
        ],
        reason: 'b.example responses (seq/ttl/time/ip) must be its own, never '
            "a.example's",
      );
      final summariesB =
          receivedB.where((d) => d.summary != null).map((d) => d.summary!);
      expect(summariesB, hasLength(1),
          reason: 'b.example must emit exactly one summary');
      final summaryB = summariesB.single;
      expect(summaryB.transmitted, 2);
      expect(summaryB.received, 2);
      expect(summaryB.time, const Duration(milliseconds: 1002));
      expect(
        summaryB.errors,
        isEmpty,
        reason: "b.example has no error; A's error must not bleed across the "
            'shared channel',
      );

      // Cross-check: run B must NEVER have seen any error at all (combined
      // response+error from A, nor a summary error).
      expect(
        receivedB.where((d) => d.error != null),
        isEmpty,
        reason: "no error event from a.example may reach b.example",
      );
    });

    test('a third run on the shared channel is unaffected by sibling traffic',
        () async {
      // Regression-style guard: a run whose events are deliberately drowned in
      // a sibling's interleaved traffic still collects only its own and closes
      // on its own summary.
      final pingA = DartPingIOS('a.example', 1, 1, 5, 64, false);
      final receivedA = <PingData>[];
      final doneA = Completer<void>();
      pingA.stream.listen(receivedA.add, onDone: doneA.complete);

      final pingB = DartPingIOS('b.example', 1, 1, 5, 64, false);
      final receivedB = <PingData>[];
      final doneB = Completer<void>();
      pingB.stream.listen(receivedB.add, onDone: doneB.complete);

      await pumpEventQueue();

      final idA = idForHost('a.example');
      final idB = idForHost('b.example');

      // Bombard B with traffic, slip one A event in, then close both.
      emitNativeEvent({'id': idB, 'type': 'response', 'seq': 1, 'ttl': 50});
      emitNativeEvent({'id': idB, 'type': 'response', 'seq': 2, 'ttl': 50});
      emitNativeEvent(
          {'id': idA, 'type': 'response', 'seq': 1, 'ttl': 99, 'ip': '9.9.9.9'});
      emitNativeEvent(
          {'id': idB, 'type': 'summary', 'transmitted': 2, 'received': 2});
      emitNativeEvent(
          {'id': idA, 'type': 'summary', 'transmitted': 1, 'received': 1});

      await Future.wait([doneA.future, doneB.future]).timeout(
        hardTimeout,
        onTimeout: () =>
            fail('a concurrent stream did not close within $hardTimeout'),
      );

      final responsesA =
          receivedA.where((d) => d.response != null).map((d) => d.response!);
      expect(responsesA, hasLength(1));
      expect(responsesA.single.seq, 1);
      expect(responsesA.single.ttl, 99,
          reason: "a.example's ttl must not be the sibling's 50");
      expect(responsesA.single.ip, '9.9.9.9');

      final summaryA =
          receivedA.firstWhere((d) => d.summary != null).summary!;
      expect(summaryA.transmitted, 1);
      expect(summaryA.received, 1);
    });
  });
}
