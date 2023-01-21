import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingLinux extends BasePing implements Ping {
  PingLinux(
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
        responseRgx: RegExp(r'from (?<ip>.*): icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>(\d+).?(\d+))'),
        sequenceRgx: RegExp(r'icmp_seq=(?<seq>\d+)'),
        summaryStr: RegExp(r'packet loss'),
        summaryRgx: RegExp(r'(?<tx>\d+) packets transmitted, (?<rx>\d+) received,.*time (?<time>\d+)ms'),
        timeoutStr: RegExp(r'no answer yet'),
        unknownHostStr: RegExp(r'unknown host|service not known|failure in name'),
      );

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  @override
  List<String> get params {
    var params = ['-O', '-n', '-W $timeout', '-i $interval', '-t $ttl'];
    if (count != null) params.add('-c $count');

    return params;
  }

  @override
  PingError? interpretExitCode(int exitCode) {
    return exitCode == 1 ? PingError(ErrorType.noReply) : null;
  }

  @override
  Exception? throwExit(int exitCode) {
    return exitCode > 1 ? Exception('Ping process exited with code: $exitCode') : null;
  }
}
