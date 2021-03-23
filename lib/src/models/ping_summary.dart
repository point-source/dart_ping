/// Summary of the results
class PingSummary {
  PingSummary(
      {required this.transmitted, required this.received, required this.time});

  /// Number of icmp packets sent to the target
  final int transmitted;

  /// Number of packets returned to the source from the target
  final int received;

  /// Total time spent for all sent/received packets to complete a round trip (summed)
  final Duration time;

  @override
  String toString() =>
      'PingSummary(transmitted:$transmitted, received:$received, time:${time.inMilliseconds} ms)';
}
