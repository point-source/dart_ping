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
  requestTimedOut('Request Timed Out'),
  unknownHost('Unknown Host'),
  unknown('Unknown Error'),
  noReply('No Reply');

  const ErrorType(this.message);

  final String message;

  static ErrorType fromMessage(String message) {
    switch (message) {
      case 'Request Timed Out':
        return ErrorType.requestTimedOut;
      case 'Unknown Host':
        return ErrorType.unknownHost;
      case 'No Reply':
        return ErrorType.noReply;
      default:
        return ErrorType.unknown;
    }
  }
}
