import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:flutter_icmp_ping/flutter_icmp_ping.dart' as fp;

class DartPingIOS implements Ping {
  DartPingIOS(this._ping);

  static void register() {
    Ping.iosFactory = _init;
  }

  // ignore: long-parameter-list
  static DartPingIOS _init(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    bool ipv6,
    PingParser? parser,
    Encoding encoding,
  ) {
    return DartPingIOS(fp.Ping(
      host,
      count: count,
      interval: interval.toDouble(),
      timeout: timeout.toDouble(),
      ipv6: ipv6,
    ));
  }

  /// Unused on iOS and should not be called
  @override
  PingParser get parser => throw UnimplementedError();

  /// Unused on iOS and should not be called
  @override
  set parser(PingParser parser) => throw UnimplementedError();

  /// zuvola's [flutter_icmp_ping] package
  final fp.Ping _ping;

  @override
  String get command =>
      'Ping on iOS is provided by the GBPing package modified by zuvola';

  /// Stop the currently running ping
  @override
  Future<bool> stop() async {
    _ping.stop();

    return true;
  }

  /// Stream of [PingData] events. One for each response, error, or summary
  @override
  Stream<PingData> get stream => _ping.stream.map((data) {
        var r = data.response;
        var s = data.summary;
        PingError? e;
        switch (data.error) {
          case null:
            break;
          case fp.PingError.requestTimedOut:
            e = const PingError(ErrorType.requestTimedOut);
            break;
          case fp.PingError.unknownHost:
            e = const PingError(ErrorType.unknownHost);
            break;
          default:
            e = const PingError(ErrorType.unknown);
            break;
        }

        return PingData(
          response: r == null
              ? null
              : PingResponse(seq: r.seq, ttl: r.ttl, time: r.time, ip: r.ip),
          summary: s == null
              ? null
              : PingSummary(
                  transmitted: s.transmitted ?? 0,
                  received: s.received ?? 0,
                  time: s.time,
                ),
          error: e,
        );
      });
}
