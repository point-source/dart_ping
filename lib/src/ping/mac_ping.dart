import 'dart:async';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/response_parser.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingMac extends BasePing implements Ping {
  PingMac(String host, int? count, double interval, double timeout, int ttl,
      bool ipv6)
      : super(host, count, interval, timeout, ttl, ipv6);

  static final _responseRgx =
      RegExp(r'from (.*): icmp_seq=(\d+) ttl=(\d+) time=((\d+).?(\d+))');
  static final _sequenceRgx = RegExp(r'icmp_seq (\d+)');
  static final _summaryRgx =
      RegExp(r'(\d+) packets transmitted, (\d+) received,.*time (\d+)ms');
  static final _responseStr = RegExp(r'bytes from');
  static final _timeoutStr = RegExp(r'Request timeout');
  static final _unknownHostStr = RegExp(r'Unknown host');
  static final _summaryStr = RegExp(r'packet loss');

  @override
  StreamTransformer<String, PingData> get parser => responseParser(
      responseRgx: _responseRgx,
      sequenceRgx: _sequenceRgx,
      summaryRgx: _summaryRgx,
      responseStr: _responseStr,
      timeoutStr: _timeoutStr,
      unknownHostStr: _unknownHostStr,
      summaryStr: _summaryStr);

  @override
  Future<Process> get platformProcess async {
    var params = ['-n', '-W ${timeout * 1000}', '-i $interval', '-m $ttl'];
    if (count != null) params.add('-c $count');
    return await Process.start(ipv6 ? 'ping6' : 'ping', [...params, host]);
  }

  @override
  PingData processSummary(int exitCode, PingData summary) {
    if (exitCode == 1) {
      summary.error = PingError(ErrorType.NoReply);
    } else if (exitCode == 68) {
      summary.error = PingError(ErrorType.UnknownHost);
    }
    return summary;
  }

  @override
  Exception? processErrors(int exitCode) {
    if (exitCode > 1 && exitCode != 68) {
      return Exception('Ping process exited with code: $exitCode');
    }
  }
}
