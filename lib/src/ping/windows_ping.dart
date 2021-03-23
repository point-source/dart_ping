import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/response_parser.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingWindows extends BasePing implements Ping {
  PingWindows(
      String host, int? count, double interval, double timeout, bool ipv6)
      : super(host, count, interval, timeout, ipv6);

  static final _responseRgx =
      RegExp(r'from (.*): bytes=(\d+) time=(\d+.?\d+)ms TTL=(\d+)');
  static final _summaryRgx =
      RegExp(r'Sent = (\d+), Received = (\d+), Lost = (\d+)');
  static final _responseStr = RegExp(r'Reply from');
  static final _summaryStr = RegExp(r'Lost');
  static final _timeoutStr = RegExp(r'host unreachable|timed out');
  static final _unknownHostStr = RegExp(r'could not find host');
  static final _errorStr = RegExp(r'transmit failed');

  Process? _process;

  @override
  Future<void> onListen() async {
    if (_process != null) {
      throw Exception('ping is already running');
    }
    if (ipv6) throw UnimplementedError('IPv6 not implemented for windows');
    var params = ['-w', timeout.toString()];
    if (count == null) {
      params.add('-t');
    } else {
      params.add('-n');
      params.add(count.toString());
    }
    _process = await Process.start('ping', [...params, host]);
    await controller.addStream(
        StreamGroup.merge([_process!.stderr, _process!.stdout])
            .transform(utf8.decoder)
            .transform(LineSplitter())
            .transform<PingData>(responseParser(
                responseRgx: _responseRgx,
                summaryRgx: _summaryRgx,
                responseStr: _responseStr,
                summaryStr: _summaryStr,
                timeoutStr: _timeoutStr,
                unknownHostStr: _unknownHostStr,
                errorStr: _errorStr)));
    await _process!.exitCode.then((value) async {
      await controller.done;
      switch (value) {
        case 0:
          break;
        default:
          throw Exception('Ping process exited with code: $value');
      }
      _process = null;
    });
  }

  @override
  Future<void> stop() async {
    if (_process == null) {
      throw Exception('Cannot kill a process that has not yet been started');
    }
    _process!.kill(ProcessSignal.sigint);
  }
}
