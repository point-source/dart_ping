import 'dart:math' as math;

import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('RoundTripStats.fromSamples', () {
    test('multi-sample set [10ms, 20ms, 30ms]', () {
      final stats = RoundTripStats.fromSamples(const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
        Duration(milliseconds: 30),
      ]);

      expect(stats.sampleCount, 3);
      expect(stats.min, const Duration(milliseconds: 10));
      expect(stats.max, const Duration(milliseconds: 30));
      expect(stats.avg, const Duration(milliseconds: 20));

      // Population stddev = sqrt(((10-20)^2 + 0 + (30-20)^2)/3) ms
      //                   = sqrt(200/3) ms ~= 8.16497 ms.
      final expectedStddevMicros = math.sqrt(200 / 3) * 1000;
      expect(
        stats.stddev!.inMicroseconds,
        closeTo(expectedStddevMicros, 2),
      );

      // Jitter = (|20-10| + |30-20|) / 2 = 10 ms.
      expect(stats.jitter, const Duration(milliseconds: 10));
    });

    test('sub-millisecond inputs retain microsecond precision', () {
      final stats = RoundTripStats.fromSamples(const [
        Duration(microseconds: 1500),
        Duration(microseconds: 2500),
      ]);

      expect(stats.sampleCount, 2);
      expect(stats.min, const Duration(microseconds: 1500));
      expect(stats.max, const Duration(microseconds: 2500));
      expect(stats.avg, const Duration(microseconds: 2000));

      // Population stddev of {1500, 2500}: mean 2000, var = ((500^2)*2)/2
      // = 250000 -> stddev 500 us.
      expect(stats.stddev, const Duration(microseconds: 500));

      // Jitter = |2500-1500| / 1 = 1000 us.
      expect(stats.jitter, const Duration(microseconds: 1000));
    });

    test('single sample', () {
      final stats =
          RoundTripStats.fromSamples(const [Duration(milliseconds: 42)]);

      expect(stats.sampleCount, 1);
      expect(stats.min, const Duration(milliseconds: 42));
      expect(stats.avg, const Duration(milliseconds: 42));
      expect(stats.max, const Duration(milliseconds: 42));
      expect(stats.stddev, Duration.zero);
      expect(stats.jitter, isNull);
    });

    test('zero replies report honestly', () {
      final stats = RoundTripStats.fromSamples(const []);

      expect(stats.sampleCount, 0);
      expect(stats.min, isNull);
      expect(stats.avg, isNull);
      expect(stats.max, isNull);
      expect(stats.stddev, isNull);
      expect(stats.jitter, isNull);
    });
  });

  group('RoundTripStatsAccumulator', () {
    test('empty accumulator snapshot', () {
      final acc = RoundTripStatsAccumulator();
      expect(acc.sampleCount, 0);

      final stats = acc.snapshot();
      expect(stats.sampleCount, 0);
      expect(stats.min, isNull);
      expect(stats.avg, isNull);
      expect(stats.max, isNull);
      expect(stats.stddev, isNull);
      expect(stats.jitter, isNull);
    });

    test('incremental equals batch', () {
      const samples = [
        Duration(microseconds: 1234),
        Duration(milliseconds: 5),
        Duration(microseconds: 9876),
        Duration(milliseconds: 12),
        Duration(microseconds: 333),
      ];

      final acc = RoundTripStatsAccumulator();
      for (final s in samples) {
        acc.add(s);
      }

      expect(acc.sampleCount, samples.length);
      expect(acc.snapshot(), RoundTripStats.fromSamples(samples));
    });
  });

  group('serialization', () {
    test('toMap/fromMap round-trip preserves sub-millisecond precision', () {
      final stats = RoundTripStats.fromSamples(const [
        Duration(microseconds: 1500),
        Duration(microseconds: 2750),
        Duration(microseconds: 3333),
      ]);

      final restored = RoundTripStats.fromMap(stats.toMap());
      expect(restored, stats);
      expect(restored.min, stats.min);
      expect(restored.avg, stats.avg);
      expect(restored.max, stats.max);
      expect(restored.stddev, stats.stddev);
      expect(restored.jitter, stats.jitter);
      expect(restored.sampleCount, stats.sampleCount);
    });

    test('toJson/fromJson round-trip', () {
      final stats = RoundTripStats.fromSamples(const [
        Duration(microseconds: 1500),
        Duration(microseconds: 2500),
      ]);

      expect(RoundTripStats.fromJson(stats.toJson()), stats);
    });

    test('zero-reply map encodes nulls', () {
      final stats = RoundTripStats.fromSamples(const []);
      final map = stats.toMap();

      expect(map['min'], isNull);
      expect(map['avg'], isNull);
      expect(map['max'], isNull);
      expect(map['stddev'], isNull);
      expect(map['jitter'], isNull);
      expect(map['sampleCount'], 0);

      expect(RoundTripStats.fromMap(map), stats);
    });
  });
}
