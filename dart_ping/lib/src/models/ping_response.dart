import 'dart:convert';

/// Each probe response
class PingResponse {
  const PingResponse({this.seq, this.ttl, this.time, this.ip});

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

  PingResponse copyWith({
    int? seq,
    int? ttl,
    Duration? time,
    String? ip,
  }) {
    return PingResponse(
      seq: seq ?? this.seq,
      ttl: ttl ?? this.ttl,
      time: time ?? this.time,
      ip: ip ?? this.ip,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingResponse &&
        other.seq == seq &&
        other.ttl == ttl &&
        other.time == time &&
        other.ip == ip;
  }

  @override
  int get hashCode {
    return seq.hashCode ^ ttl.hashCode ^ time.hashCode ^ ip.hashCode;
  }

  Map<String, dynamic> toMap() {
    return {
      'seq': seq,
      'ttl': ttl,
      'time': time?.inMilliseconds,
      'ip': ip,
    };
  }

  factory PingResponse.fromMap(Map<String, dynamic> map) {
    return PingResponse(
      seq: map['seq']?.toInt(),
      ttl: map['ttl']?.toInt(),
      time: map['time'] != null ? Duration(milliseconds: map['time']) : null,
      ip: map['ip'],
    );
  }

  String toJson() => json.encode(toMap());

  factory PingResponse.fromJson(String source) =>
      PingResponse.fromMap(json.decode(source));
}
