part of 'ping_event.dart';

/// Each probe response — the successful-probe variant of [PingEvent].
final class PingResponse extends PingEvent {
  const PingResponse({this.seq, this.ttl, this.time, this.ip, this.stats});

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

  /// A running snapshot of round-trip stats over all successful replies seen
  /// so far in the run, at the moment this event was emitted (§spec:stats-live).
  ///
  /// Null on events not produced by the live run path (e.g. a bare parsed or
  /// deserialized response).
  final RoundTripStats? stats;

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
    RoundTripStats? stats,
  }) {
    return PingResponse(
      seq: seq ?? this.seq,
      ttl: ttl ?? this.ttl,
      time: time ?? this.time,
      ip: ip ?? this.ip,
      stats: stats ?? this.stats,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PingResponse &&
        other.seq == seq &&
        other.ttl == ttl &&
        other.time == time &&
        other.ip == ip &&
        other.stats == stats;
  }

  @override
  int get hashCode {
    return seq.hashCode ^
        ttl.hashCode ^
        time.hashCode ^
        ip.hashCode ^
        stats.hashCode;
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'type': 'response',
      'seq': seq,
      'ttl': ttl,
      'time': time?.inMilliseconds,
      'ip': ip,
      'stats': stats?.toMap(),
    };
  }

  factory PingResponse.fromMap(Map<String, dynamic> map) {
    return PingResponse(
      seq: map['seq']?.toInt(),
      ttl: map['ttl']?.toInt(),
      time: map['time'] != null ? Duration(milliseconds: map['time']) : null,
      ip: map['ip'],
      stats: map['stats'] != null
          ? RoundTripStats.fromMap(map['stats'] as Map<String, dynamic>)
          : null,
    );
  }

  factory PingResponse.fromJson(String source) =>
      PingResponse.fromMap(json.decode(source) as Map<String, dynamic>);
}
