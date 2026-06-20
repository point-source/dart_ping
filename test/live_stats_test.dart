import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// Live-consistency tests for the running statistics feature
/// (§spec:stats-live / §spec:stats-tests). These prove that every emitted
/// probe event carries a running [RoundTripStats] snapshot, that the snapshot
/// tracks the same computation as the terminal summary step by step, that the
/// LAST probe event's snapshot equals the terminal `summary.stats`, and that
/// loss-so-far derived from the running counts agrees with the terminal
/// `packetLoss`. All offline — no network, no real subprocess.

const _hardTimeout = Duration(seconds: 5);

/// In-memory [Process] stand-in that emits canned stdout lines then exits.
/// Mirrors the private copy in `stats_event_test.dart` (each suite keeps its
/// own copy of the harness).
class FakeProcess implements Process {
  FakeProcess({List<String> stdoutLines = const [], required int exit})
      : _stdout = Stream<List<int>>.fromIterable(
          stdoutLines.map((l) => utf8.encode('$l\n')),
        ),
        _exitCode = Future<int>.value(exit);

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

/// [PingLinux] whose process launch is replaced by a [FakeProcess], so the real
/// shared parse/accumulate engine runs deterministically on any host.
class TestPing extends PingLinux {
  TestPing({required FakeProcess process})
      : _process = process,
        super('1.1.1.1', null, 1000, 1000, 255, IpVersion.ipv4);

  final FakeProcess _process;

  @override
  Future<Process> get platformProcess async => _process;
}

/// The last event that is a probe (a [PingResponse] or a [PingError]) — i.e.
/// the last event before the terminal [PingSummary]. Used to assert the
/// running snapshot at the end of the run equals the summary's figures.
PingEvent _lastProbeEvent(List<PingEvent> events) =>
    events.lastWhere((e) => e is PingResponse || e is PingError);

/// Packet-loss percentage from running counts, using the SAME formula the
/// terminal summary derives (§spec:stats-summary) so the comparison is exact,
/// not float-fuzzy.
double _lossPct(int transmitted, int received) =>
    transmitted == 0 ? 100.0 : 100 * (transmitted - received) / transmitted;

void main() {
  group('Live running stats — every probe carries a snapshot '
      '(§spec:stats-live / §spec:stats-tests)', () {
    test('every PingResponse and PingError carries a non-null stats snapshot '
        'across a mixed reply/timeout run', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            'no answer yet for icmp_seq=2',
            '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=30.0 ms',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);

      final probes = events.where((e) => e is PingResponse || e is PingError);
      expect(probes, isNotEmpty);
      for (final probe in probes) {
        expect(probe.stats, isNotNull,
            reason: 'every probe event must carry a running snapshot');
      }
    });
  });

  group('Live running stats — snapshot tracks the summary computation '
      '(§spec:stats-live / §spec:stats-tests)', () {
    test('the i-th response snapshot equals fromSamples([rtt_0..rtt_i])',
        () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            '64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=20.0 ms',
            '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=30.0 ms',
            '3 packets transmitted, 3 received, 0% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final responses = events.whereType<PingResponse>().toList();
      expect(responses, hasLength(3));

      const rtts = [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
        Duration(milliseconds: 30),
      ];

      for (var i = 0; i < responses.length; i++) {
        final expected = RoundTripStats.fromSamples(rtts.sublist(0, i + 1));
        expect(responses[i].stats, equals(expected),
            reason: 'snapshot on response #$i must summarize the first '
                '${i + 1} replies and use identical computation');
        // The snapshot grows one sample at a time as replies arrive.
        expect(responses[i].stats!.sampleCount, i + 1);
      }
    });

    test("a timeout's snapshot equals the snapshot of the successful replies "
        'seen so far — errors do not contribute RTT', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            '64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=20.0 ms',
            'no answer yet for icmp_seq=3',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);

      final error = events.whereType<PingError>().single;
      expect(error.error, ErrorType.requestTimedOut);

      // Two successful replies precede the timeout; the timeout carries their
      // snapshot unchanged (no RTT added by the error).
      final expected = RoundTripStats.fromSamples(const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ]);
      expect(error.stats, equals(expected));
      expect(error.stats!.sampleCount, 2);

      // ...and it equals the snapshot of the last preceding response.
      final lastResponseBeforeError = events
          .takeWhile((e) => e != error)
          .whereType<PingResponse>()
          .last;
      expect(error.stats, equals(lastResponseBeforeError.stats));
    });
  });

  group('Live running stats — last snapshot equals the terminal summary '
      '(§spec:stats-live / §spec:stats-tests)', () {
    test('run ending in a successful reply: last probe snapshot == '
        'summary.stats', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            'no answer yet for icmp_seq=2',
            '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=30.0 ms',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final summary = events.whereType<PingSummary>().single;
      final lastProbe = _lastProbeEvent(events);

      expect(lastProbe, isA<PingResponse>());
      expect(lastProbe.stats, equals(summary.stats));
      expect(summary.stats!.sampleCount, 2);
    });

    test('run whose last probe event is a timeout: last probe snapshot still '
        '== summary.stats (no reply follows it)', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            '64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=30.0 ms',
            'no answer yet for icmp_seq=3',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final summary = events.whereType<PingSummary>().single;
      final lastProbe = _lastProbeEvent(events);

      expect(lastProbe, isA<PingError>());
      expect((lastProbe as PingError).error, ErrorType.requestTimedOut);
      // The terminal consistency criterion holds even when the final probe is
      // an error: its snapshot reflects all replies, and none follow it.
      expect(lastProbe.stats, equals(summary.stats));
      expect(summary.stats!.sampleCount, 2);
    });

    test('zero-reply run: every probe carries the empty sampleCount-0 snapshot, '
        'equal to the summary empty stats', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            'no answer yet for icmp_seq=1',
            'no answer yet for icmp_seq=2',
            '2 packets transmitted, 0 received, 100% packet loss, time 1001ms',
          ],
          exit: 1, // Linux maps exit 1 to noReply.
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final summary = events.whereType<PingSummary>().single;

      const empty = RoundTripStats(sampleCount: 0);
      expect(summary.stats, equals(empty));

      final probes = events.where((e) => e is PingResponse || e is PingError);
      expect(probes, isNotEmpty);
      for (final probe in probes) {
        final stats = probe.stats!;
        expect(stats.sampleCount, 0);
        expect(stats, equals(empty));
        expect(stats, equals(summary.stats));
      }

      final lastProbe = _lastProbeEvent(events);
      expect(lastProbe.stats, equals(summary.stats));
    });
  });

  group('Live running stats — loss-so-far matches terminal loss '
      '(§spec:stats-live / §spec:stats-tests)', () {
    test('derived running loss at the final probe equals summary.packetLoss',
        () async {
      // Canned native summary: 3 transmitted, 2 received -> 33% loss.
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            'no answer yet for icmp_seq=2',
            '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=30.0 ms',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final summary = events.whereType<PingSummary>().single;

      // Transmitted-so-far = count of probe events; received-so-far =
      // running sampleCount on the final probe.
      final probes =
          events.where((e) => e is PingResponse || e is PingError).toList();
      final transmittedSoFar = probes.length;
      final receivedSoFar = _lastProbeEvent(events).stats!.sampleCount;

      expect(transmittedSoFar, 3);
      expect(receivedSoFar, 2);

      final derivedLoss = _lossPct(transmittedSoFar, receivedSoFar);
      expect(derivedLoss, summary.packetLoss);
      expect(derivedLoss, closeTo(33.33, 0.01));
    });

    test('zero-reply run: derived running loss is 100%, matching summary',
        () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            'no answer yet for icmp_seq=1',
            'no answer yet for icmp_seq=2',
            '2 packets transmitted, 0 received, 100% packet loss, time 1001ms',
          ],
          exit: 1,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);
      final summary = events.whereType<PingSummary>().single;

      final probes =
          events.where((e) => e is PingResponse || e is PingError).toList();
      final transmittedSoFar = probes.length;
      final receivedSoFar = _lastProbeEvent(events).stats!.sampleCount;

      expect(receivedSoFar, 0);
      final derivedLoss = _lossPct(transmittedSoFar, receivedSoFar);
      expect(derivedLoss, 100.0);
      expect(derivedLoss, summary.packetLoss);
    });
  });
}
