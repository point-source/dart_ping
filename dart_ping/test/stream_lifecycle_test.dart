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
  FakeProcess({
    List<String> stdoutLines = const [],
    List<String> stderrLines = const [],
    required int exit,
  })  : _stdout = Stream<List<int>>.fromIterable(
          stdoutLines.map((l) => utf8.encode('$l\n')),
        ),
        _stderr = Stream<List<int>>.fromIterable(
          stderrLines.map((l) => utf8.encode('$l\n')),
        ),
        _exitCode = Future<int>.value(exit);

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
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  int get pid => throw UnimplementedError();

  @override
  IOSink get stdin => throw UnimplementedError();
}

/// [PingLinux] subclass that replaces the OS process launch with either a
/// configured [FakeProcess] or a launch failure. All parsing and exit-code
/// interpretation are inherited from [PingLinux] unchanged.
class TestPing extends PingLinux {
  TestPing({
    FakeProcess? process,
    Object? launchError,
  })  : _process = process,
        _launchError = launchError,
        super('1.1.1.1', 5, 1000, 1000, 255, IpVersion.ipv4);

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
}

/// Result of draining a ping stream to completion.
class _Collected {
  final List<PingData> data = [];
  final List<Object> errors = [];
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
      collected.doneCount++;
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

      expect(result.errors, hasLength(1),
          reason: 'exactly one error event expected on launch failure');
      expect(result.errors.single.toString(), contains('ping binary'));
      expect(result.errors.single.toString(),
          contains('Could not find ping binary'));
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

      expect(result.errors, isNotEmpty,
          reason: 'unmapped non-zero exit must surface an error');
      expect(result.errors.first.toString(),
          contains('Ping process exited with code: 2'));
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

      expect(result.errors, isEmpty,
          reason: 'a clean run must not surface an error');
      expect(result.doneCount, 1, reason: 'stream must close exactly once');

      final responses = result.data
          .where((d) => d.response != null)
          .map((d) => d.response!)
          .toList();
      expect(responses, hasLength(2), reason: 'two per-probe responses');
      expect(responses[0].seq, 1);
      expect(responses[0].ttl, 57);
      expect(responses[0].ip, '1.1.1.1');
      expect(responses[1].seq, 2);
      expect(responses[1].ttl, 57);

      final summaries = result.data.where((d) => d.summary != null).toList();
      expect(summaries, hasLength(1), reason: 'one run summary expected');
      final summary = summaries.single.summary!;
      expect(summary.transmitted, 5);
      expect(summary.received, 5);
      expect(summary.time, const Duration(milliseconds: 4005));
      // Per-run error list is present and empty on a clean run.
      expect(summary.errors, isEmpty);
    });

    test('(b2) a typed noRoute event AND the unmapped-exit error both surface',
        () async {
      // A noRoute line surfaces a typed PingData(error: noRoute) and the process
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

      final errorData = result.data.where((d) => d.error != null).toList();
      expect(errorData, hasLength(1));
      expect(errorData.single.error!.error, ErrorType.noRoute,
          reason: 'the routing failure surfaces as a typed PingData event');
      expect(result.errors, hasLength(1),
          reason: 'the unmapped exit still surfaces a catchable error');
      expect(result.errors.single.toString(),
          contains('Ping process exited with code: 2'));
      expect(result.doneCount, 1, reason: 'stream must close exactly once');
    });

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
}
