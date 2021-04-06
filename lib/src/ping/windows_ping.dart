import 'dart:async';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/response_parser.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingWindows extends BasePing implements Ping {
  PingWindows(String host, int? count, double interval, double timeout, int ttl,
      bool ipv6)
      : super(host, count, interval, timeout, ttl, ipv6);

  static final _responseRgx =
      RegExp(r'from (.*): bytes=\d+() time=(\d+)ms TTL=(\d+)');
  static final _summaryRgx =
      RegExp(r'Sent = (\d+), Received = (\d+), Lost = (\d+)');
  static final _responseStr = RegExp(r'Reply from');
  static final _summaryStr = RegExp(r'Lost');
  static final _timeoutStr = RegExp(r'host unreachable|timed out');
  static final _unknownHostStr = RegExp(r'could not find host');
  static final _errorStr = RegExp(r'transmit failed');

  @override
  StreamTransformer<String, PingData> get parser => responseParser(
      responseRgx: _responseRgx,
      summaryRgx: _summaryRgx,
      responseStr: _responseStr,
      summaryStr: _summaryStr,
      timeoutStr: _timeoutStr,
      unknownHostStr: _unknownHostStr,
      errorStr: _errorStr);

  @override
  Future<Process> get platformProcess async {
    if (ipv6) throw UnimplementedError('IPv6 not implemented for windows');
    var params = ['-w', timeout.toString(), '-I', ttl.toString()];
    if (count == null) {
      params.add('-t');
    } else {
      params.add('-n');
      params.add(count.toString());
    }
    return await Process.start('ping', [...params, host]);
  }

  @override
  PingData processSummary(int exitCode, PingData summary) => summary;

  @override
  Exception? processErrors(int exitCode) {
    if (exitCode > 0) {
      return Exception('Ping process exited with code: $exitCode');
    }
  }
}
