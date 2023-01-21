import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingMac extends BasePing implements Ping {
  PingMac(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    bool ipv6, {
    PingParser? parser,
    Encoding encoding = const Utf8Codec(),
  }) : super(
          host,
          count,
          interval,
          timeout,
          ttl,
          ipv6,
          parser ?? _parser,
          encoding,
        );

  static PingParser get _parser => PingParser(
        responseStr: RegExp(r'bytes from'),
        responseRgx: RegExp(
          r'from (?<ip>.*): icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>(\d+).?(\d+))',
        ),
        sequenceRgx: RegExp(r'icmp_seq (?<seq>\d+)'),
        summaryStr: RegExp(r'packet loss'),
        summaryRgx: RegExp(
          r'(?<tx>\d+) packets transmitted, (?<rx>\d+) packets received',
        ),
        timeoutStr: RegExp(r'Request timeout'),
        unknownHostStr: RegExp(r'Unknown host'),
      );

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  @override
  List<String> get params {
    var params = ['-n', '-W ${timeout * 1000}', '-i $interval', '-m $ttl'];
    if (count != null) params.add('-c $count');

    return params;
  }

  @override
  PingError? interpretExitCode(int exitCode) {
    if (exitCode == 1) {
      return PingError(ErrorType.noReply);
    } else if (exitCode == 68) {
      return PingError(ErrorType.unknownHost);
    }

    return null;
  }

  @override
  Exception? throwExit(int exitCode) {
    if (exitCode > 1 && exitCode != 68) {
      return Exception('Ping process exited with code: $exitCode');
    }

    return null;
  }
}
