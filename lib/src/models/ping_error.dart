/// Error code
class PingError {
  PingError(this.error, {this.message});

  final ErrorType error;
  final String? message;

  String get _errorStr =>
      error.toString().substring(error.toString().indexOf('.') + 1);

  @override
  String toString() =>
      message == null ? _errorStr.toString() : '$_errorStr: $message';
}

enum ErrorType { RequestTimedOut, UnknownHost, Unknown, NoReply }
