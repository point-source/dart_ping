import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// Tests for the sealed-event contract, derived packet loss, the zero-reply
/// absence contract, and the cross-platform per-probe stats computation
/// (§spec:stats-tests). All offline — no network, no real subprocess.

const _hardTimeout = Duration(seconds: 5);

/// In-memory [Process] stand-in that emits canned stdout lines then exits.
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

void main() {
  group('Event contract (§spec:stats-event-model)', () {
    test('responses are PingResponse, errors PingError, summary PingSummary '
        'and the summary is the FINAL event', () async {
      final ping = TestPing(
        process: FakeProcess(
          stdoutLines: const [
            '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.0 ms',
            'no answer yet for icmp_seq=2',
            '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=12.0 ms',
            '3 packets transmitted, 2 received, 33% packet loss, time 2003ms',
          ],
          exit: 0,
        ),
      );

      final events = await ping.stream.toList().timeout(_hardTimeout);

      // Distinguishable by type alone — no null inspection.
      expect(events.whereType<PingResponse>(), hasLength(2));
      expect(events.whereType<PingError>(), hasLength(1));
      expect(events.whereType<PingSummary>(), hasLength(1));

      // The terminal summary is the final event.
      expect(events.last, isA<PingSummary>());
      // ...and only the last event is a summary.
      expect(
        events.sublist(0, events.length - 1).whereType<PingSummary>(),
        isEmpty,
      );

      final err = events.whereType<PingError>().single;
      expect(err.error, ErrorType.requestTimedOut);
      expect(err.seq, 2);
    });
  });

  group('Packet-loss derivation (§spec:stats-summary)', () {
    test('loss tracks the counts', () {
      expect(PingSummary(transmitted: 10, received: 7).packetLoss, 30.0);
      expect(PingSummary(transmitted: 5, received: 5).packetLoss, 0.0);
      expect(PingSummary(transmitted: 8, received: 2).packetLoss, 75.0);
    });

    test('zero-reply reports 100% loss and absent round-trip figures', () {
      final summary = PingSummary(
        transmitted: 4,
        received: 0,
        stats: const RoundTripStats(sampleCount: 0),
      );
      expect(summary.packetLoss, 100.0);
      expect(summary.stats!.sampleCount, 0);
      expect(summary.stats!.min, isNull);
      expect(summary.stats!.avg, isNull);
      expect(summary.stats!.max, isNull);
      expect(summary.stats!.stddev, isNull);
      expect(summary.stats!.jitter, isNull);
    });

    test('transmitted == 0 reports 100% loss', () {
      expect(PingSummary(transmitted: 0, received: 0).packetLoss, 100.0);
    });
  });

  group('Stats from per-probe RTTs (§spec:stats-cross-platform)', () {
    test('feeding per-probe RTTs through the accumulator yields populated '
        'stats including a non-null stddev', () {
      // This is the exact path BasePing uses to build the summary stats.
      final acc = RoundTripStatsAccumulator();
      acc.add(const Duration(milliseconds: 10));
      acc.add(const Duration(milliseconds: 20));
      acc.add(const Duration(milliseconds: 30));
      final stats = acc.snapshot();

      expect(stats.sampleCount, 3);
      expect(stats.min, const Duration(milliseconds: 10));
      expect(stats.max, const Duration(milliseconds: 30));
      expect(stats.avg, const Duration(milliseconds: 20));
      // stddev is computed the same way on every platform (incl. Windows).
      expect(stats.stddev, isNotNull);
      expect(stats.stddev!.inMicroseconds, greaterThan(0));
      expect(stats.jitter, isNotNull);
    });

    test(
      'BasePing builds summary stats from the per-probe reply times',
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
        final summary = events.whereType<PingSummary>().single;

        final expected = RoundTripStats.fromSamples(const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
          Duration(milliseconds: 30),
        ]);
        expect(summary.stats, equals(expected));
        expect(summary.stats!.stddev, isNotNull);
        expect(summary.packetLoss, 0.0);
      },
    );

    test('a run with no replies yields an empty (absent-figures) stats '
        'snapshot', () async {
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

      expect(summary.packetLoss, 100.0);
      expect(summary.stats!.sampleCount, 0);
      expect(summary.stats!.avg, isNull);
      // The two timeouts plus the exit-code noReply are folded into errors.
      expect(
        summary.errors.map((e) => e.error),
        contains(ErrorType.requestTimedOut),
      );
      expect(summary.errors.map((e) => e.error), contains(ErrorType.noReply));
    });
  });
}
