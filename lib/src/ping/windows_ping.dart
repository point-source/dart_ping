import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/dart_ping_base.dart';

class PingWindows extends BasePing implements Ping {
  PingWindows(
      String host, int count, double interval, double timeout, bool ipv6)
      : super(host, count, interval, timeout, ipv6);

  static final _resRegex =
      RegExp(r'from (.*): bytes=(\d+) time=(\d+.?\d+)ms TTL=(\d+)');
  static final _summaryRegexes = [
    RegExp(r'Sent = (\d+), Received = (\d+), Lost = (\d+)'),
    RegExp(r'Minimum = (\d+)ms, Maximum = (\d+)ms, Average = (\d+)ms'),
  ];

  Process _process;

  @override
  Future<void> onListen() async {
    if (_process != null) {
      throw Exception('ping is already running');
    }
    if (ipv6) throw UnimplementedError('IPv6 not implemented for windows');
    var params = [];
    if (count == null) {
      params.add('-t');
    } else {
      params.add('-n');
      params.add(count.toString());
    }
    if (timeout != null) {
      params.add('-w');
      params.add(timeout.toString());
    }
    _process = await Process.start('ping', [...params, host]);
    // ignore: unawaited_futures
    _process.exitCode.then((value) {
      controller.close();
    });
    subscription = StreamGroup.merge([_process.stderr, _process.stdout])
        .transform(utf8.decoder)
        .transform(LineSplitter())
        .transform<PingData>(_windowsTransformer)
        .listen(controller.add);
  }

  @override
  void stop() {
    _process?.kill(ProcessSignal.sigint);
    _process = null;
  }

  /// StreamTransformer for Android response from process stdout/stderr.
  static final StreamTransformer<String, PingData> _windowsTransformer =
      StreamTransformer.fromHandlers(
    handleData: (data, sink) {
      if (data.contains('Reply from')) {
        if (data.contains('host unreachable')) {
          sink.add(
            PingData(
              error: PingError.RequestTimedOut,
            ),
          );
        }
        final match = _resRegex.firstMatch(data);
        if (match == null) {
          return;
        }
        sink.add(
          PingData(
            response: PingResponse(
              ip: match.group(1),
              ttl: int.parse(match.group(4)),
              time: Duration(
                  microseconds:
                      ((double.parse(match.group(3))) * 1000).floor()),
            ),
          ),
        );
      }
      if (data.contains('could not find host')) {
        sink.add(
          PingData(
            error: PingError.UnknownHost,
          ),
        );
      }
      if (data.contains('transmit failed')) {
        sink.add(
          PingData(
            error: PingError.Unknown,
          ),
        );
      }
      if (data.contains('timed out')) {
        sink.add(
          PingData(
            error: PingError.RequestTimedOut,
          ),
        );
      }
      if (data.contains('Lost')) {
        final match = _summaryRegexes[0].firstMatch(data);
        final transmitted = match.group(1);
        final received = match.group(2);
        if (transmitted == null || received == null) {
          return;
        }
        sink.add(
          PingData(
            summary: PingSummary(
              transmitted: int.parse(transmitted),
              received: int.parse(received),
            ),
          ),
        );
      }
    },
  );
}
