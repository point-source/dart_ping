import 'dart:convert';

import 'package:dart_ping/src/models/ping_error.dart';
import 'package:dart_ping/src/models/ping_response.dart';
import 'package:dart_ping/src/models/ping_summary.dart';

/// Ping response data
class PingData {
  const PingData({this.response, this.summary, this.error});

  /// A singly ping response from the target
  final PingResponse? response;

  /// A summary of results from previous ping responses
  final PingSummary? summary;

  /// An error reported by the ping process
  final PingError? error;

  @override
  String toString() => summary == null
      ? error == null
          ? response.toString()
          : 'PingError(response:$response, error:$error)'
      : summary.toString();

  PingData copyWith({
    PingResponse? response,
    PingSummary? summary,
    PingError? error,
  }) {
    return PingData(
      response: response ?? this.response,
      summary: summary ?? this.summary,
      error: error ?? this.error,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingData &&
        other.response == response &&
        other.summary == summary &&
        other.error == error;
  }

  @override
  int get hashCode => response.hashCode ^ summary.hashCode ^ error.hashCode;

  Map<String, dynamic> toMap() {
    return {
      'response': response?.toMap(),
      'summary': summary?.toMap(),
      'error': error?.toMap(),
    };
  }

  factory PingData.fromMap(Map<String, dynamic> map) {
    return PingData(
      response: map['response'] != null
          ? PingResponse.fromMap(map['response'])
          : null,
      summary:
          map['summary'] != null ? PingSummary.fromMap(map['summary']) : null,
      error: map['error'] != null ? PingError.fromMap(map['error']) : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory PingData.fromJson(String source) =>
      PingData.fromMap(json.decode(source));
}
