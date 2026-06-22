import 'dart:convert';
import 'dart:math' as math;

/// Decodes a serialized round-trip duration (stored in **microseconds** to
/// preserve sub-millisecond precision) back into a [Duration], or null when the
/// field is absent.
///
/// This is the single home for the microsecond decode convention; the model
/// `fromMap`s in `ping_event.dart` reuse it (round_trip_stats.dart is the
/// lower-level library they import, so the helper lives here). It is not
/// re-exported from the public `dart_ping` barrel.
Duration? durationFromMicros(Object? value) =>
    value is num ? .new(microseconds: value.toInt()) : null;

/// Immutable round-trip statistics value object (§spec:stats-round-trip).
///
/// Carries the round-trip figures — minimum, average, maximum, standard
/// deviation, and jitter — together with the count of successful samples they
/// were computed from. The same type backs both the final run summary and the
/// live running snapshot, and is computed incrementally by
/// [RoundTripStatsAccumulator] so the two can never diverge.
///
/// All figures are computed over **successful replies only**. A timed-out,
/// TTL-exceeded, or otherwise errored probe never contributes to these
/// figures.
///
/// Null/absent contract:
/// - `sampleCount == 0`: [min], [avg], [max], [stddev], [jitter] are all null
///   (honest absence, not fabricated zeros).
/// - `sampleCount == 1`: [min] / [avg] / [max] equal the single value,
///   [stddev] is [Duration.zero] (the population stddev of one sample is 0),
///   and [jitter] is null (it needs at least two samples).
/// - `sampleCount >= 2`: all five figures are present.
class RoundTripStats {
  /// Smallest successful round-trip time, or null when [sampleCount] is 0.
  final Duration? min;

  /// Arithmetic mean of the successful round-trip times, or null when
  /// [sampleCount] is 0.
  final Duration? avg;

  /// Largest successful round-trip time, or null when [sampleCount] is 0.
  final Duration? max;

  /// **Population** standard deviation of the successful round-trip times
  /// (dividing by the sample count N), matching what native `ping` tools
  /// report so a computed value is comparable to a native number.
  ///
  /// Computed in microseconds as `sqrt(sumOfSquares / N − mean²)`. Null when
  /// [sampleCount] is 0; [Duration.zero] when [sampleCount] is 1.
  final Duration? stddev;

  /// **Jitter** — the mean of the absolute differences between consecutive
  /// successful round-trip times (RFC 3550-style interarrival variation),
  /// i.e. `sum(|rtt[i] − rtt[i-1]|) / (N − 1)`.
  ///
  /// This is probe-to-probe variation, not a deviation from the mean. Null
  /// when fewer than two samples are present ([sampleCount] < 2).
  final Duration? jitter;

  /// Count of successful samples the figures summarize.
  final int sampleCount;

  @override
  int get hashCode {
    return min.hashCode ^
        avg.hashCode ^
        max.hashCode ^
        stddev.hashCode ^
        jitter.hashCode ^
        sampleCount.hashCode;
  }

  /// Creates a [RoundTripStats] from already-computed figures.
  ///
  /// Honoring the null/absent contract is the caller's responsibility; prefer
  /// [RoundTripStats.fromSamples] or [RoundTripStatsAccumulator] to build a
  /// contract-correct instance.
  const RoundTripStats({
    this.min,
    this.avg,
    this.max,
    this.stddev,
    this.jitter,
    required this.sampleCount,
  });

  /// Builds contract-correct stats from a full list of successful RTTs.
  ///
  /// Delegates to [RoundTripStatsAccumulator] so the batch result is identical
  /// to feeding the same samples one at a time.
  factory RoundTripStats.fromSamples(Iterable<Duration> rtts) {
    final acc = RoundTripStatsAccumulator();
    for (final rtt in rtts) {
      acc.add(rtt);
    }

    return acc.snapshot();
  }

  factory RoundTripStats.fromMap(Map<String, dynamic> map) {
    return RoundTripStats(
      min: durationFromMicros(map['min']),
      avg: durationFromMicros(map['avg']),
      max: durationFromMicros(map['max']),
      stddev: durationFromMicros(map['stddev']),
      jitter: durationFromMicros(map['jitter']),
      sampleCount: map['sampleCount']?.toInt() ?? 0,
    );
  }

  factory RoundTripStats.fromJson(String source) =>
      RoundTripStats.fromMap(json.decode(source));

  @override
  String toString() {
    return 'RoundTripStats(min: $min, avg: $avg, max: $max, '
        'stddev: $stddev, jitter: $jitter, sampleCount: $sampleCount)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is RoundTripStats &&
        other.min == min &&
        other.avg == avg &&
        other.max == max &&
        other.stddev == stddev &&
        other.jitter == jitter &&
        other.sampleCount == sampleCount;
  }

  /// Serializes to a map. Duration fields are encoded in **microseconds** to
  /// preserve sub-millisecond precision.
  Map<String, dynamic> toMap() {
    return {
      'min': min?.inMicroseconds,
      'avg': avg?.inMicroseconds,
      'max': max?.inMicroseconds,
      'stddev': stddev?.inMicroseconds,
      'jitter': jitter?.inMicroseconds,
      'sampleCount': sampleCount,
    };
  }

  String toJson() => json.encode(toMap());
}

/// Mutable helper that computes [RoundTripStats] **incrementally** as
/// successful replies arrive (§spec:stats-round-trip).
///
/// Using one accumulator for both the live snapshot and the final summary
/// guarantees the two define `avg` / `stddev` / `jitter` identically.
///
/// Invariant: adding the same RTTs one at a time and calling [snapshot]
/// produces the same result as [RoundTripStats.fromSamples] over the same
/// list.
class RoundTripStatsAccumulator {
  int _count = 0;
  int _sumMicros = 0;
  double _sumOfSquares = 0;
  int? _minMicros;
  int? _maxMicros;
  int? _previousMicros;
  int _sumAbsDeltaMicros = 0;

  /// Memoized result of [snapshot], invalidated on every [add]. Repeated reads
  /// between adds — e.g. a run of error events (which don't change the figures)
  /// or the terminal summary right after the last reply — return the cached
  /// instance instead of recomputing and allocating a fresh [RoundTripStats].
  RoundTripStats? _cachedSnapshot;

  /// Number of successful samples ingested so far.
  int get sampleCount => _count;

  /// Ingests one successful reply's round-trip time.
  void add(Duration rtt) {
    final micros = rtt.inMicroseconds;

    // The figures change, so any memoized snapshot is now stale.
    _cachedSnapshot = null;

    _count += 1;
    _sumMicros += micros;
    _sumOfSquares += micros.toDouble() * micros.toDouble();

    final currentMin = _minMicros;
    if (currentMin == null || micros < currentMin) {
      _minMicros = micros;
    }
    final currentMax = _maxMicros;
    if (currentMax == null || micros > currentMax) {
      _maxMicros = micros;
    }

    final previous = _previousMicros;
    if (previous != null) {
      _sumAbsDeltaMicros += (micros - previous).abs();
    }
    _previousMicros = micros;
  }

  /// Returns a [RoundTripStats] reflecting all RTTs added so far, honoring the
  /// null/absent contract. The result is memoized until the next [add], so
  /// repeated reads between adds reuse one immutable instance.
  RoundTripStats snapshot() => _cachedSnapshot ??= _computeSnapshot();

  RoundTripStats _computeSnapshot() {
    final minMicros = _minMicros;
    final maxMicros = _maxMicros;
    // A non-zero count guarantees min/max were set; the explicit null checks let
    // the compiler promote the locals so no non-null assertion is needed below.
    if (_count == 0 || minMicros == null || maxMicros == null) {
      return const RoundTripStats(sampleCount: 0);
    }

    final mean = _sumMicros / _count;

    // Population variance: sumOfSquares/N − mean². Clamp at 0 to guard against
    // tiny negative values from floating-point rounding.
    final variance = math.max(0.0, (_sumOfSquares / _count) - (mean * mean));
    final stddevMicros = math.sqrt(variance);

    final jitter = _count >= 2
        ? Duration(microseconds: (_sumAbsDeltaMicros / (_count - 1)).round())
        : null;

    return RoundTripStats(
      min: Duration(microseconds: minMicros),
      avg: Duration(microseconds: mean.round()),
      max: Duration(microseconds: maxMicros),
      stddev: Duration(microseconds: stddevMicros.round()),
      jitter: jitter,
      sampleCount: _count,
    );
  }
}
