import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/response_parser.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingLinux extends BasePing implements Ping {
  PingLinux(String host, int? count, double interval, double timeout, int ttl,
      bool ipv6)
      : super(host, count, interval, timeout, ttl, ipv6);

  static final _responseRgx =
      RegExp(r'from (.*): icmp_seq=(\d+) ttl=(\d+) time=((\d+).?(\d+))');
  static final _sequenceRgx = RegExp(r'icmp_seq=(\d+)');
  static final _summaryRgx =
      RegExp(r'(\d+) packets transmitted, (\d+) received,.*time (\d+)ms');
  static final _responseStr = RegExp(r'bytes from');
  static final _timeoutStr = RegExp(r'no answer yet');
  static final _unknownHostStr =
      RegExp(r'unknown host|service not known|failure in name');
  static final _summaryStr = RegExp(r'packet loss');

  Process? _process;
  PingData? _summary;

  @override
  Future<void> onListen() async {
    if (_process != null) {
      throw Exception('ping is already running');
    }
    var params = ['-O', '-n', '-W $timeout', '-i $interval', '-t $ttl'];
    if (count != null) params.add('-c $count');
    _process = await Process.start(ipv6 ? 'ping6' : 'ping', [...params, host]);
    final sub = StreamGroup.merge([_process!.stderr, _process!.stdout])
        .transform(utf8.decoder)
        .transform(LineSplitter())
        .transform<PingData>(responseParser(
            responseRgx: _responseRgx,
            sequenceRgx: _sequenceRgx,
            summaryRgx: _summaryRgx,
            responseStr: _responseStr,
            timeoutStr: _timeoutStr,
            unknownHostStr: _unknownHostStr,
            summaryStr: _summaryStr))
        .listen((event) {
      if (event.summary != null) {
        _summary = event;
      } else {
        controller.add(event);
      }
    });
    await sub.asFuture();
    await _process!.exitCode.then((value) async {
      if (_summary != null) {
        if (value == 1) {
          _summary!.error = PingError(ErrorType.NoReply);
        }
        controller.add(_summary!);
      }
      if (value > 1) {
        controller.addError(Exception('Ping process exited with code: $value'));
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
