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
/// Each line is emitted on its own microtask-spaced future, so when two
/// [FakeProcess] instances run at the same time their stdout events are
/// genuinely interleaved in time through the shared `BasePing` parse/accumulate
/// path. That maximizes the chance of exposing cross-contamination between the
/// two concurrent runs.
class FakeProcess implements Process {
  FakeProcess({List<String> stdoutLines = const [], required int exit})
    : _stdout = _interleaved(stdoutLines),
      _exitCode = Future<int>.value(exit);

  /// Emits each line on a separate async tick so the merged line stream's
  /// events from two concurrent processes are interleaved rather than delivered
  /// as one synchronous burst.
  static Stream<List<int>> _interleaved(List<String> lines) async* {
    for (final line in lines) {
      // Yield control between lines so a sibling process can emit in between.
      await Future<void>.delayed(Duration.zero);
      yield utf8.encode('$line\n');
    }
  }

  final Stream<List<int>> _stdout;
  final Future<int> _exitCode;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  int get pid => throw UnimplementedError();

  @override
  IOSink get stdin => throw UnimplementedError();
}

/// [PingLinux] subclass that replaces the OS process launch with a configured
/// [FakeProcess]. All parsing, accumulation, and exit-code interpretation are
/// inherited from [PingLinux] / [BasePing] unchanged, so the test exercises the
/// REAL shared engine seam, just without a network or subprocess.
///
/// [PingLinux] is instantiated directly (not through the [Ping] platform
/// factory) so the test is deterministic on any host OS.
class TestPing extends PingLinux {
  TestPing(String host, {required FakeProcess process})
    : _process = process,
      super(host, null, 1000, 1000, 255, IpVersion.ipv4);

  final FakeProcess _process;

  @override
  Future<Process> get platformProcess async => _process;
}

/// One host's canned, distinct ping output plus the values it should produce.
class _HostFixture {
  _HostFixture({
    required this.host,
    required this.lines,
    required this.expectedResponses,
    required this.expectedTransmitted,
    required this.expectedReceived,
    required this.expectedSummaryTime,
    required this.expectedErrors,
  });

  final String host;
  final List<String> lines;
  final List<PingResponse> expectedResponses;
  final int expectedTransmitted;
  final int expectedReceived;
  final Duration expectedSummaryTime;
  final List<ErrorType> expectedErrors;
}

void main() {
  group('concurrent-isolation (§spec:concurrent-isolation)', () {
    // Host A: distinct ttl (57) and time (170.0 ms). It also has a timeout on
    // seq=2 (no reply), so its run records ONE error. If `_errors` bled between
    // runs, host B's summary would wrongly carry this error too.
    final hostA = _HostFixture(
      host: 'a.example',
      lines: const [
        '64 bytes from 154.16.146.45: icmp_seq=1 ttl=57 time=170.0 ms',
        'no answer yet for icmp_seq=2',
        '2 packets transmitted, 1 received, 50% packet loss, time 1001ms',
      ],
      expectedResponses: [
        const PingResponse(
          seq: 1,
          ttl: 57,
          time: Duration(microseconds: 170000),
          ip: '154.16.146.45',
        ),
        // The timeout line yields a single PingError (seq=2), not a response.
      ],
      expectedTransmitted: 2,
      expectedReceived: 1,
      expectedSummaryTime: const Duration(milliseconds: 1001),
      expectedErrors: const [ErrorType.requestTimedOut],
    );

    // Host B: deliberately DIFFERENT ttl (53) and time (236.0 ms) so any swap
    // or bleed of those fields from host A is detectable. Host B has NO error,
    // so its summary's error list must stay empty.
    final hostB = _HostFixture(
      host: 'b.example',
      lines: const [
        '64 bytes from 187.188.169.169: icmp_seq=1 ttl=53 time=236.0 ms',
        '64 bytes from 187.188.169.169: icmp_seq=2 ttl=53 time=240.0 ms',
        '2 packets transmitted, 2 received, 0% packet loss, time 1002ms',
      ],
      expectedResponses: [
        const PingResponse(
          seq: 1,
          ttl: 53,
          time: Duration(microseconds: 236000),
          ip: '187.188.169.169',
        ),
        const PingResponse(
          seq: 2,
          ttl: 53,
          time: Duration(microseconds: 240000),
          ip: '187.188.169.169',
        ),
      ],
      expectedTransmitted: 2,
      expectedReceived: 2,
      expectedSummaryTime: const Duration(milliseconds: 1002),
      expectedErrors: const [],
    );

    /// Asserts a drained run reflects ONLY [fixture]'s own canned data — no
    /// field copied from a concurrently-running sibling.
    void expectIsolated(List<PingEvent> data, _HostFixture fixture) {
      // Emitted responses now carry a running `stats` snapshot (§spec:stats-live);
      // that is not what this isolation test asserts, so compare only the
      // identifying fields by stripping `stats` to a bare response.
      final responses = data
          .whereType<PingResponse>()
          .map(
            (r) => PingResponse(seq: r.seq, ttl: r.ttl, time: r.time, ip: r.ip),
          )
          .toList();
      expect(
        responses,
        fixture.expectedResponses,
        reason:
            '${fixture.host} responses (seq/ttl/time/ip) must match only '
            'its own canned input, not the sibling run',
      );

      final summaries = data.whereType<PingSummary>().toList();
      expect(
        summaries,
        hasLength(1),
        reason: '${fixture.host} must emit exactly one summary',
      );
      final summary = summaries.single;
      expect(
        summary.transmitted,
        fixture.expectedTransmitted,
        reason: '${fixture.host} transmitted count must be its own',
      );
      expect(
        summary.received,
        fixture.expectedReceived,
        reason: '${fixture.host} received count must be its own',
      );
      expect(
        summary.time,
        fixture.expectedSummaryTime,
        reason: '${fixture.host} summary time must be its own',
      );
      expect(
        summary.errors.map((e) => e.error).toList(),
        fixture.expectedErrors,
        reason:
            '${fixture.host} error list must reflect only its own run; '
            'no error may bleed from the sibling',
      );
    }

    test('two concurrent runs to distinct hosts stay fully isolated', () async {
      final pingA = TestPing(
        hostA.host,
        process: FakeProcess(stdoutLines: hostA.lines, exit: 0),
      );
      final pingB = TestPing(
        hostB.host,
        process: FakeProcess(stdoutLines: hostB.lines, exit: 0),
      );

      // Drain both streams CONCURRENTLY so their interleaved events pass through
      // the shared parse/accumulate path at the same time.
      final results =
          await Future.wait(<Future<List<PingEvent>>>[
            pingA.stream.toList(),
            pingB.stream.toList(),
          ]).timeout(
            _hardTimeout,
            onTimeout: () =>
                fail('concurrent streams hung within $_hardTimeout'),
          );

      expectIsolated(results[0], hostA);
      expectIsolated(results[1], hostB);
    });

    test('sequential runs return the same distinct, isolated results', () async {
      // Regression guard: pinging one host at a time must yield each host's own
      // results unchanged — proving the fix changes nothing for sequential use.
      final pingA = TestPing(
        hostA.host,
        process: FakeProcess(stdoutLines: hostA.lines, exit: 0),
      );
      final dataA = await pingA.stream.toList().timeout(_hardTimeout);
      expectIsolated(dataA, hostA);

      final pingB = TestPing(
        hostB.host,
        process: FakeProcess(stdoutLines: hostB.lines, exit: 0),
      );
      final dataB = await pingB.stream.toList().timeout(_hardTimeout);
      expectIsolated(dataB, hostB);
    });
  });
}
