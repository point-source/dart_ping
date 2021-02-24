import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingLinux extends BasePing implements Ping {
  PingLinux(String host, int count, double interval, double timeout, bool ipv6)
      : super(host, count, interval, timeout, ipv6);

  static final _resRegex =
      RegExp(r'from (.*): icmp_seq=(\d+) ttl=(\d+) time=((\d+).?(\d+))');
  static final _seqRegex = RegExp(r'icmp_seq=(\d+)');
  static final _summaryRegexes = [
    RegExp(r'(\d+) packets transmitted'),
    RegExp(r'(\d+) received'),
    RegExp(r'time (\d+)ms'),
  ];

  Process _process;

  @override
  Future<void> onListen() async {
    if (_process != null) {
      throw Exception('ping is already running');
    }
    var params = ['-O', '-n'];
    if (count != null) params.add('-c $count');
    if (timeout != null) params.add('-W $timeout');
    if (interval != null) params.add('-i $interval');
    _process = await Process.start(
        (ipv6 ?? false) ? 'ping6' : 'ping', [...params, host]);
    // ignore: unawaited_futures
    _process.exitCode.then((value) {
      controller.close();
    });
    subscription = StreamGroup.merge([_process.stderr, _process.stdout])
        .transform(utf8.decoder)
        .transform(LineSplitter())
        .transform<PingData>(_linuxTransformer)
        .listen(controller.add);
  }

  @override
  void stop() {
    _process?.kill(ProcessSignal.sigint);
    _process = null;
  }

  /// StreamTransformer for Android response from process stdout/stderr.
  static final StreamTransformer<String, PingData> _linuxTransformer =
      StreamTransformer.fromHandlers(
    handleData: (data, sink) {
      if (data.contains('unknown host')) {
        sink.add(
          PingData(
            error: PingError.UnknownHost,
          ),
        );
      }
      if (data.contains('bytes from')) {
        final match = _resRegex.firstMatch(data);
        if (match == null) {
          return;
        }
        sink.add(
          PingData(
            response: PingResponse(
              ip: match.group(1),
              seq: int.parse(match.group(2)) - 1,
              ttl: int.parse(match.group(3)),
              time: Duration(
                  microseconds:
                      ((double.parse(match.group(4))) * 1000).floor()),
            ),
          ),
        );
      }
      if (data.contains('no answer yet')) {
        final match = _seqRegex.firstMatch(data);
        if (match == null) {
          return;
        }
        sink.add(
          PingData(
            response: PingResponse(
              seq: int.parse(match.group(2)) - 1,
            ),
            error: PingError.RequestTimedOut,
          ),
        );
      }
      if (data.contains('packet loss')) {
        final transmitted = _summaryRegexes[0].firstMatch(data);
        final received = _summaryRegexes[1].firstMatch(data);
        final time = _summaryRegexes[2].firstMatch(data);
        if (transmitted == null || received == null || time == null) {
          return;
        }
        sink.add(
          PingData(
            summary: PingSummary(
              transmitted: int.parse(transmitted.group(1)),
              received: int.parse(received.group(1)),
              time: Duration(milliseconds: int.parse(time.group(1))),
            ),
          ),
        );
      }
    },
  );
}
