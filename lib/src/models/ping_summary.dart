/// Summary of the results
class PingSummary {
  final int transmitted;
  final int received;
  final Duration time;

  PingSummary({this.transmitted, this.received, this.time});

  @override
  String toString() =>
      'PingSummary(transmitted:$transmitted, received:$received, time:${time.inMilliseconds} ms)';
}
