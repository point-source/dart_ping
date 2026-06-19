part of 'ping_event.dart';

/// Summary of the results — the terminal run-summary variant of [PingEvent].
///
/// This is the final event a run emits; it is identifiable by type alone
/// (`is PingSummary`).
final class PingSummary extends PingEvent {
  PingSummary({
    required this.transmitted,
    required this.received,
    this.time,
    this.stats,
    List<PingError>? errors,
  }) {
    this.errors = errors ?? [];
  }

  /// Number of icmp packets sent to the target
  final int transmitted;

  /// Number of packets returned to the source from the target
  final int received;

  /// Total wall-clock duration of the ping session as reported by the OS.
  /// On Linux/Android, this includes interval delays between pings.
  /// On macOS and Windows, this value is null.
  final Duration? time;

  /// Round-trip statistics computed from the per-probe reply times of this run
  /// (§spec:stats-summary). Null until finalized; the empty snapshot reports
  /// the round-trip figures as absent when no reply was received.
  @override
  final RoundTripStats? stats;

  /// All errors that occurred during the ping process
  late final List<PingError> errors;

  /// Packet-loss percentage DERIVED on read from [transmitted]/[received] —
  /// never stored, so it cannot drift from the counts. A run that transmitted
  /// nothing, or received nothing, reports 100% loss.
  double get packetLoss =>
      transmitted == 0 ? 100.0 : 100 * (transmitted - received) / transmitted;

  @override
  String toString() {
    var str = 'PingSummary(transmitted:$transmitted, received:$received';
    str = '$str, loss:$packetLoss%';
    if (time != null) {
      str = '$str, time: ${time!.inMilliseconds} ms';
    }
    if (stats != null) {
      str = '$str, stats: $stats';
    }
    str = '$str)';
    if (errors.isNotEmpty) {
      str = '$str, Errors: $errors';
    }

    return str;
  }

  PingSummary copyWith({
    int? transmitted,
    int? received,
    Duration? time,
    RoundTripStats? stats,
    List<PingError>? errors,
  }) {
    return PingSummary(
      transmitted: transmitted ?? this.transmitted,
      received: received ?? this.received,
      time: time ?? this.time,
      stats: stats ?? this.stats,
      errors: errors ?? this.errors,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingSummary &&
        other.transmitted == transmitted &&
        other.received == received &&
        other.time == time &&
        other.stats == stats &&
        ListEquality().equals(other.errors, errors);
  }

  @override
  int get hashCode {
    return transmitted.hashCode ^
        received.hashCode ^
        time.hashCode ^
        stats.hashCode ^
        // Hash the errors element-wise so equal summaries (== compares the
        // list element-wise via ListEquality) always share a hashCode.
        const ListEquality().hash(errors);
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'type': 'summary',
      'transmitted': transmitted,
      'received': received,
      'time': time?.inMilliseconds,
      'stats': stats?.toMap(),
      'errors': errors.map((e) => e.toMap()).toList(),
    };
  }

  factory PingSummary.fromMap(Map<String, dynamic> map) {
    return PingSummary(
      transmitted: map['transmitted']?.toInt() ?? 0,
      received: map['received']?.toInt() ?? 0,
      time: map['time'] != null ? Duration(milliseconds: map['time']) : null,
      stats: map['stats'] != null ? RoundTripStats.fromMap(map['stats']) : null,
      errors: map['errors'] is List
          ? map['errors'].map<PingError>((e) => PingError.fromMap(e)).toList()
          : null,
    );
  }

  factory PingSummary.fromJson(String source) =>
      PingSummary.fromMap(json.decode(source) as Map<String, dynamic>);
}
