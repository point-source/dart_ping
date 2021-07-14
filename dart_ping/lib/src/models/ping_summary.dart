import 'package:dart_ping/src/models/ping_error.dart';

/// Summary of the results
class PingSummary {
  PingSummary(
      {required this.transmitted,
      required this.received,
      this.time,
      List<PingError>? errors}) {
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
}
