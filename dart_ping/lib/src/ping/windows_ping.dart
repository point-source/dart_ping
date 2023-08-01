import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingWindows extends BasePing implements Ping {
  PingWindows(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    bool ipv6, {
    PingParser? parser,
    Encoding encoding = const Utf8Codec(),
    bool forceCodepage = false,
  }) : super(
          host,
          count,
          interval,
          timeout,
          ttl,
          ipv6,
          parser ?? defaultParser,
          encoding,
          forceCodepage,
        );

  static PingParser get defaultParser => PingParser(
        responseRgx: RegExp(
          r'Reply from (?<ip>.*): bytes=(?:\d+) time(?:=|<)(?<time>\d+)ms TTL=(?<ttl>\d+)',
        ),
        summaryRgx:
            RegExp(r'Sent = (?<tx>\d+), Received = (?<rx>\d+), Lost = (?:\d+)'),
        timeoutRgx: RegExp(r'Request timed out'),
        timeToLiveRgx: RegExp(r'Reply from (?<ip>.*): TTL expired in transit'),
        unknownHostStr: RegExp(r'could not find host'),
        errorStrs: [
          RegExp(r'General failure'),
          RegExp(r'Destination host unreachable'),
        ],
      );

  @override
  Map<String, String> get locale => {'LANG': 'en_US'};

  @override
  List<String> get params {
    if (ipv6) throw UnimplementedError('IPv6 not implemented for windows');
    var params = ['-w', (timeout * 1000).toString(), '-i', ttl.toString()];
    if (ipv6) {
      params.add('-6');
    } else {
      params.add('-4');
    }
    if (count == null) {
      params.add('-t');
    } else {
      params.add('-n');
      params.add(count.toString());
    }

    return params;
  }

  @override
  PingError? interpretExitCode(int exitCode) => PingError(
        ErrorType.unknown,
        message: 'Ping process exited with code: $exitCode',
      );

  @override
  Exception throwExit(int exitCode) =>
      Exception('Ping process exited with code: $exitCode');
}
