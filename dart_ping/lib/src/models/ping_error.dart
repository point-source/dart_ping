part of 'ping_event.dart';

/// The probe/run error variant of [PingEvent].
///
/// Reused both as the error EVENT on the stream and as the element type of
/// [PingSummary.errors]. An error that names a specific probe (a timeout, or a
/// TTL-exceeded hop) carries that probe's [seq] and, when present, the hop [ip]
/// — so a probe that both identifies itself and reports an error stays a single
/// event (§spec:ios-error-parity, §spec:address-family-error-honesty).
final class PingError extends PingEvent {
  const PingError(this.error, {this.message, this.seq, this.ip});

  final ErrorType error;
  final String? message;

  /// Probe sequence id, when the error names a probe (timeout / TTL-exceeded).
  final int? seq;

  /// Hop ip, when present (TTL-exceeded).
  final String? ip;

  String get _errorStr =>
      error.toString().substring(error.toString().indexOf('.') + 1);

  @override
  String toString() {
    final buff = StringBuffer(
      message == null ? _errorStr.toString() : '$_errorStr: $message',
    );
    if (seq != null) buff.write(', seq:$seq');
    if (ip != null) buff.write(', ip:$ip');

    return buff.toString();
  }

  PingError copyWith({
    ErrorType? error,
    String? message,
    int? seq,
    String? ip,
  }) {
    return PingError(
      error ?? this.error,
      message: message ?? this.message,
      seq: seq ?? this.seq,
      ip: ip ?? this.ip,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingError &&
        other.error == error &&
        other.message == message &&
        other.seq == seq &&
        other.ip == ip;
  }

  @override
  int get hashCode =>
      error.hashCode ^ message.hashCode ^ seq.hashCode ^ ip.hashCode;

  @override
  Map<String, dynamic> toMap() {
    return {
      'type': 'error',
      'error': error.message,
      'message': message,
      'seq': seq,
      'ip': ip,
    };
  }

  factory PingError.fromMap(Map<String, dynamic> map) {
    return PingError(
      ErrorType.fromMessage(map['error'] ?? ''),
      message: map['message'],
      seq: map['seq']?.toInt(),
      ip: map['ip'],
    );
  }

  factory PingError.fromJson(String source) =>
      PingError.fromMap(json.decode(source) as Map<String, dynamic>);
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
