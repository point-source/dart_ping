/// Each probe response
class PingResponse {
  final int seq;
  final int ttl;
  final Duration time;
  final String ip;

  PingResponse({this.seq, this.ttl, this.time, this.ip});

  @override
  String toString() {
    final buff = StringBuffer('PingResponse(seq:$seq');
    if (ip != null) buff.write(', ip:$ip');
    if (ttl != null) buff.write(', ttl:$ttl');
    if (time != null) {
      final ms = time.inMicroseconds / Duration.millisecondsPerSecond;
      buff.write(', time:$ms ms');
    }
    buff.write(')');
    return buff.toString();
  }
}
