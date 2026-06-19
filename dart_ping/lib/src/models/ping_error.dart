import 'dart:convert';

/// Error code
class PingError {
  const PingError(this.error, {this.message});

  final ErrorType error;
  final String? message;

  String get _errorStr =>
      error.toString().substring(error.toString().indexOf('.') + 1);

  @override
  String toString() =>
      message == null ? _errorStr.toString() : '$_errorStr: $message';

  PingError copyWith({
    ErrorType? error,
    String? message,
  }) {
    return PingError(
      error ?? this.error,
      message: message ?? this.message,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingError &&
        other.error == error &&
        other.message == message;
  }

  @override
  int get hashCode => error.hashCode ^ message.hashCode;

  Map<String, dynamic> toMap() {
    return {
      'error': error.message,
      'message': message,
    };
  }

  factory PingError.fromMap(Map<String, dynamic> map) {
    return PingError(
      ErrorType.fromMessage(map['error'] ?? ''),
      message: map['message'],
    );
  }

  String toJson() => json.encode(toMap());

  factory PingError.fromJson(String source) =>
      PingError.fromMap(json.decode(source));
}

enum ErrorType {
  timeToLiveExceeded('Time To Live Exceeded'),
  requestTimedOut('Request Timed Out'),
  unknownHost('Unknown Host'),
  unknown('Unknown Error'),
  noReply('No Reply'),

  /// The network or adapter cannot route the selected address family: no route
  /// to the host, network unreachable, or the requested family is unavailable.
  ///
  /// This is distinct from [unknownHost] (a genuine name-resolution failure of
  /// a real hostname) and from the catch-all [unknown]. On an IPv6-only network
  /// an IPv4 literal legitimately has "no route for this family" (#69); the
  /// honest, branchable error is this value rather than a misleading
  /// "Unknown Host".
  noRoute('No Route');

  const ErrorType(this.message);

  final String message;

  static ErrorType fromMessage(String message) {
    switch (message) {
      case 'Time To Live Exceeded':
        return ErrorType.timeToLiveExceeded;
      case 'Request Timed Out':
        return ErrorType.requestTimedOut;
      case 'Unknown Host':
        return ErrorType.unknownHost;
      case 'No Reply':
        return ErrorType.noReply;
      case 'No Route':
        return ErrorType.noRoute;
      default:
        return ErrorType.unknown;
    }
  }
}
