/// Each probe response
class PingResponse {
  PingResponse({this.seq, this.ttl, this.time, this.ip});

  /// Transmission sequence position identifier
  /// (can be used to reconstruct packet order)
  final int? seq;

  /// Time-to-live
  /// Number of hops a packet will traverse in its way to a target
  /// Once a packet exceeds the ttl, it is dropped and will not return
  final int? ttl;

  /// Time it took for the packet to make a round trip
  final Duration? time;

  /// IP Address of the target
  final String? ip;

  @override
  String toString() {
    final buff = StringBuffer('PingResponse(seq:$seq');
    if (ip != null) buff.write(', ip:$ip');
    if (ttl != null) buff.write(', ttl:$ttl');
    if (time != null) {
      final ms = time!.inMicroseconds / Duration.millisecondsPerSecond;
      buff.write(', time:$ms ms');
    }
    buff.write(')');
    return buff.toString();
  }
}
