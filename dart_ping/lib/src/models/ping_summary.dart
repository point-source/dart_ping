import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_ping/src/models/ping_error.dart';

/// Summary of the results
class PingSummary {
  PingSummary({
    required this.transmitted,
    required this.received,
    this.time,
    List<PingError>? errors,
  }) {
    this.errors = errors ?? [];
  }

  /// Number of icmp packets sent to the target
  final int transmitted;

  /// Number of packets returned to the source from the target
  final int received;

  /// Total time spent for all sent/received packets to complete a round trip (summed)
  final Duration? time;

  /// All errors that occurred during the ping process
  late final List<PingError> errors;

  @override
  String toString() {
    var str = 'PingSummary(transmitted:$transmitted, received:$received)';
    if (time != null) {
      str = str + ', time: ${time?.inMilliseconds ?? ''} ms';
    }
    if (errors.isNotEmpty) {
      str = str + ', Errors: ' + errors.toString();
    }

    return str;
  }

  PingSummary copyWith({
    int? transmitted,
    int? received,
    Duration? time,
    List<PingError>? errors,
  }) {
    return PingSummary(
      transmitted: transmitted ?? this.transmitted,
      received: received ?? this.received,
      time: time ?? this.time,
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
        ListEquality().equals(other.errors, errors);
  }

  @override
  int get hashCode {
    return transmitted.hashCode ^
        received.hashCode ^
        time.hashCode ^
        errors.hashCode;
  }

  Map<String, dynamic> toMap() {
    return {
      'transmitted': transmitted,
      'received': received,
      'time': time?.inMilliseconds,
      'errors': errors.map((e) => e.toMap()).toList(),
    };
  }

  factory PingSummary.fromMap(Map<String, dynamic> map) {
    return PingSummary(
      transmitted: map['transmitted']?.toInt() ?? 0,
      received: map['received']?.toInt() ?? 0,
      time: map['time'] != null ? Duration(milliseconds: map['time']) : null,
      errors: map['errors'] is List
          ? map['errors'].map<PingError>((e) => PingError.fromMap(e)).toList()
          : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory PingSummary.fromJson(String source) =>
      PingSummary.fromMap(json.decode(source));
}
