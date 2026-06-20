import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// Hard ceiling for every awaited completion. A hung stream never closes, so
/// the timeout converts a hang into a deterministic test failure instead of
/// blocking the whole suite.
const _hardTimeout = Duration(seconds: 5);

/// Controllable in-memory [Process] stand-in. No real OS process is started,
/// so these tests run with NO network and NO subprocess.
///
/// The stdout/stderr streams are built from [Stream.fromIterable], so they
/// emit their chunks and then close. That closure is what lets the merged line
/// stream complete and `onDone` (`_cleanup`) fire.
class FakeProcess implements Process {
  final Stream<List<int>> _stdout;

  final Stream<List<int>> _stderr;
  final Future<int> _exitCode;
  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  Future<int> get exitCode => _exitCode;

  @override
  int get pid => throw UnimplementedError();

  @override
  IOSink get stdin => throw UnimplementedError();

  FakeProcess({
    List<String> stdoutLines = const [],
    List<String> stderrLines = const [],
    required int exit,
  }) : _stdout = Stream.fromIterable(
         stdoutLines.map((l) => utf8.encode('$l\n')),
       ),
       _stderr = Stream.fromIterable(
         stderrLines.map((l) => utf8.encode('$l\n')),
       ),
       _exitCode = Future.value(exit);

  @override
  bool kill([ProcessSignal signal = .sigterm]) => true;
}

/// [PingLinux] subclass that replaces the OS process launch with either a
/// configured [FakeProcess] or a launch failure. All parsing and exit-code
/// interpretation are inherited from [PingLinux] unchanged.
class TestPing extends PingLinux {
  final FakeProcess? _process;

  final Object? _launchError;
  @override
  Future<Process> get platformProcess async {
    final launchError = _launchError;
    if (launchError != null) {
      throw launchError;
    }

    return _process!;
  }

  TestPing({FakeProcess? process, Object? launchError})
    : _process = process,
      _launchError = launchError,
      super('1.1.1.1', 5, 1000, 1000, 255, .ipv4);
}

/// Result of draining a ping stream to completion.
class _Collected {
  final data = <PingEvent>[];
  final errors = <Object>[];
  int doneCount = 0;
}

/// Listens to [ping.stream], collecting data and error events and counting how
/// many times the stream's done callback fires. Awaits completion under a hard
/// timeout so a hang FAILS the test rather than blocking the suite.
Future<_Collected> _drain(Ping ping) async {
  final collected = _Collected();
  final completer = Completer<void>();

  ping.stream.listen(
    collected.data.add,
    onError: collected.errors.add,
    onDone: () {
      collected.doneCount += 1;
      if (!completer.isCompleted) completer.complete();
    },
  );

  await completer.future.timeout(
    _hardTimeout,
    onTimeout: () => fail('Stream hung: done never fired within $_hardTimeout'),
  );

  return collected;
}

void main() {
  group('stream-lifecycle-robustness (§spec:stream-lifecycle-robustness)', () {
    test('(a) missing-binary launch failure emits error and closes', () async {
      // ProcessException.toString() contains 'No such file or directory',
      // which the fix maps to the binary-not-found message.
      final ping = TestPing(
        launchError: const ProcessException(
          'ping',
          [],
          'No such file or directory',
          2,
        ),
      );

      final result = await _drain(ping);

      expect(
        result.errors,
        hasLength(1),
        reason: 'exactly one error event expected on launch failure',
      );
      expect(result.errors.single.toString(), contains('ping binary'));
      expect(
        result.errors.single.toString(),
        contains('Could not find ping binary'),
      );
      expect(result.doneCount, 1, reason: 'stream must close exactly once');
    });

    test('(b) unmapped non-zero exit emits error and closes', () async {
      // exitCode 2 -> interpretExitCode returns null, throwExit returns an
      // Exception that must be surfaced (not swallowed).
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
          ],
          exit: 2,
        ),
      );

      final result = await _drain(ping);

      expect(
        result.errors,
        isNotEmpty,
        reason: 'unmapped non-zero exit must surface an error',
      );
      expect(
        result.errors.first.toString(),
        contains('Ping process exited with code: 2'),
      );
      expect(result.doneCount, 1, reason: 'stream must close exactly once');
    });

    test('(c) regression guard - normal completion', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
            '64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=11.2 ms',
            '5 packets transmitted, 5 received, 0% packet loss, time 4005ms',
          ],
          exit: 0,
        ),
      );

      final result = await _drain(ping);

      expect(
        result.errors,
        isEmpty,
        reason: 'a clean run must not surface an error',
      );
      expect(result.doneCount, 1, reason: 'stream must close exactly once');

      final responses = result.data.whereType<PingResponse>().toList();
      expect(responses, hasLength(2), reason: 'two per-probe responses');
      expect(responses.first.seq, 1);
      expect(responses.first.ttl, 57);
      expect(responses.first.ip, '1.1.1.1');
      expect(responses[1].seq, 2);
      expect(responses[1].ttl, 57);

      final summaries = result.data.whereType<PingSummary>().toList();
      expect(summaries, hasLength(1), reason: 'one run summary expected');
      final summary = summaries.single;
      expect(summary.transmitted, 5);
      expect(summary.received, 5);
      expect(summary.time, const Duration(milliseconds: 4005));
      // Stats are computed from the two per-probe replies.
      expect(summary.stats?.sampleCount, 2);
      // Per-run error list is present and empty on a clean run.
      expect(summary.errors, isEmpty);
    });

    test(
      '(b2) a typed noRoute event AND the unmapped-exit error both surface',
      () async {
        // A noRoute line surfaces a typed PingError(noRoute) and the process
        // also exits non-zero (2, unmapped). The unmapped-exit error is still
        // surfaced — the exit code is an independent signal from the parsed line,
        // so it is NOT suppressed (suppressing it would also hide a distinct exit
        // after unrelated timeouts). The stream still closes exactly once.
        final ping = TestPing(
          process: FakeProcess(
            stderrLines: const ['connect: Network is unreachable'],
            exit: 2,
          ),
        );

        final result = await _drain(ping);

        final errorData = result.data.whereType<PingError>().toList();
        expect(errorData, hasLength(1));
        expect(
          errorData.single.error,
          ErrorType.noRoute,
          reason: 'the routing failure surfaces as a typed PingError event',
        );
        expect(
          result.errors,
          hasLength(1),
          reason: 'the unmapped exit still surfaces a catchable error',
        );
        expect(
          result.errors.single.toString(),
          contains('Ping process exited with code: 2'),
        );
        expect(result.doneCount, 1, reason: 'stream must close exactly once');
      },
    );

    group('(d) close-exactly-once across terminal paths', () {
      test('normal completion closes once', () async {
        final ping = TestPing(
          process: FakeProcess(
            stdoutLines: const [
              '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
              '5 packets transmitted, 5 received, 0% packet loss, time 4005ms',
            ],
            exit: 0,
          ),
        );
        final result = await _drain(ping);
        expect(result.doneCount, 1);
      });

      test('unmapped exit closes once', () async {
        final ping = TestPing(
          process: FakeProcess(
            stdoutLines: const [
              '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
            ],
            exit: 2,
          ),
        );
        final result = await _drain(ping);
        expect(result.doneCount, 1);
      });

      test('launch failure closes once', () async {
        final ping = TestPing(
          launchError: const ProcessException(
            'ping',
            [],
            'No such file or directory',
            2,
          ),
        );
        final result = await _drain(ping);
        expect(result.doneCount, 1);
      });

      test('drain() returns within timeout on normal completion', () async {
        final ping = TestPing(
          process: FakeProcess(
            stdoutLines: const [
              '5 packets transmitted, 5 received, 0% packet loss, time 4005ms',
            ],
            exit: 0,
          ),
        );
        // drain() resolves only if the stream closes; the timeout converts a
        // hang into a failure.
        await ping.stream.drain().timeout(_hardTimeout);
      });

      test('stop() returns after the stream terminates', () async {
        final ping = TestPing(
          process: FakeProcess(
            stdoutLines: const [
              '5 packets transmitted, 5 received, 0% packet loss, time 4005ms',
            ],
            exit: 0,
          ),
        );
        // Begin consuming so the controller has a listener and starts the
        // process; stop() awaits controller.done, which must return.
        final result = _drain(ping);
        await ping.stop().timeout(_hardTimeout);
        await result;
      });
    });
  });

  group('bad-interface error-then-close (§spec:interface-platform-rejection)', () {
    // A chosen interface / source address that does not exist (or has no
    // connectivity) is NOT a new failure mode: the OS `ping` binary refuses
    // the bind and exits non-zero. That non-zero exit is already routed
    // through the stream's error channel and bounded-time closure by
    // §spec:stream-lifecycle-robustness — no new mechanism is introduced.
    // Here we model it network-free as a FakeProcess that emits a
    // bind-failure stderr line and exits with code 2, which
    // PingLinux.interpretExitCode does NOT map to a known PingError, so it is
    // surfaced verbatim as an exit exception. The live-hardware variant is
    // the manual @Tags(['live']) path and stays out of scope here.

    test('bad interface (refused bind) emits error then closes once', () async {
      final ping = TestPing(
        process: FakeProcess(
          stderrLines: const ['ping: SO_BINDTODEVICE: No such device'],
          exit: 2,
        ),
      );

      final result = await _drain(ping);

      // (1) The consumer receives at least one catchable error event, and it
      // is the surfaced exit exception (its text contains the exit code).
      expect(
        result.errors,
        isNotEmpty,
        reason:
            'a refused bind / non-existent interface must surface an '
            'error on the stream',
      );
      expect(
        result.errors.first.toString(),
        contains('Ping process exited with code: 2'),
      );

      // (2) The stream then closes exactly once within the hard timeout —
      // no hang.
      expect(result.doneCount, 1, reason: 'stream must close exactly once');
    });

    test(
      'bad source address (cannot assign) emits error then closes once',
      () async {
        final ping = TestPing(
          process: FakeProcess(
            stderrLines: const ['ping: bind: Cannot assign requested address'],
            exit: 2,
          ),
        );

        final result = await _drain(ping);

        expect(
          result.errors,
          isNotEmpty,
          reason:
              'a source address with no connectivity must surface an '
              'error on the stream',
        );
        expect(
          result.errors.first.toString(),
          contains('Ping process exited with code: 2'),
        );
        expect(result.doneCount, 1, reason: 'stream must close exactly once');
      },
    );

    test('awaiting consumer returns within timeout on bad interface', () async {
      final ping = TestPing(
        process: FakeProcess(
          stderrLines: const ['ping: SO_BINDTODEVICE: No such device'],
          exit: 2,
        ),
      );
      // An awaiting consumer that catches the surfaced error still observes
      // onDone — the stream always closes. The timeout converts a hang into a
      // failure.
      final done = Completer<void>();
      ping.stream.listen(
        null,
        onError: (Object _) {},
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(_hardTimeout);
    });
  });

  group('terminal summary always emitted & self-consistent '
      '(§spec:stats-event-model / §spec:stats-summary)', () {
    test('unmapped exit with replies but no native summary line still emits a '
        'consistent terminal summary', () async {
      // One reply (seq 1) and one timeout (seq 2), an unmapped non-zero exit,
      // and NO "N packets transmitted ..." line — so BasePing takes the
      // synthetic-summary fallback. Previously that path either emitted nothing
      // or reported transmitted:0/received:0 alongside non-empty stats (a
      // self-contradictory 100% loss). It must now emit a terminal summary
      // whose counts agree with the stats.
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
            'no answer yet for icmp_seq=2',
          ],
          exit: 2,
        ),
      );

      final result = await _drain(ping);

      // (finding 3) A terminal PingSummary is emitted and is the FINAL event.
      final summaries = result.data.whereType<PingSummary>().toList();
      expect(
        summaries,
        hasLength(1),
        reason:
            'a terminal summary must be emitted even without a native '
            'summary line',
      );
      expect(
        result.data.last,
        isA<PingSummary>(),
        reason: 'the summary is the final event of the run',
      );

      // (finding 2) Counts are reconstructed consistently: received equals the
      // successful-reply sample count, transmitted adds the one probe failure,
      // and loss is therefore 50% — never a fabricated 100% while stats show a
      // reply.
      final summary = summaries.single;
      expect(summary.received, 1);
      expect(
        summary.received,
        summary.stats?.sampleCount,
        reason: 'received must equal the stats sample count',
      );
      expect(summary.transmitted, 2, reason: '1 reply + 1 timed-out probe');
      expect(summary.packetLoss, 50.0);
      expect(
        summary.time,
        isNull,
        reason: 'no OS wall-clock without the native summary line',
      );
      // The unmapped exit still surfaces a catchable error.
      expect(
        result.errors.single.toString(),
        contains('Ping process exited with code: 2'),
      );
      expect(result.doneCount, 1);
    });

    test('zero-exit run with no native summary line still emits a terminal '
        'summary', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.1 ms',
          ],
          exit: 0,
        ),
      );

      final result = await _drain(ping);

      final summaries = result.data.whereType<PingSummary>().toList();
      expect(
        summaries,
        hasLength(1),
        reason:
            'a clean run with no parsed summary line still terminates '
            'with a PingSummary',
      );
      expect(result.data.last, isA<PingSummary>());
      final summary = summaries.single;
      expect(summary.received, 1);
      expect(summary.transmitted, 1);
      expect(summary.packetLoss, 0.0);
      expect(result.errors, isEmpty);
      expect(result.doneCount, 1);
    });
  });
}
