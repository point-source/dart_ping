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
    Encoding encoding = const Utf8Codec(allowMalformed: true),
    bool forceCodepage = false,
    String? interface,
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
          interface,
        ) {
    // Windows `ping` binds ONLY by source address, never by interface name.
    // Reject a bare name once, up front at construction (consistent with the
    // iOS rejection), rather than throwing lazily from the `command`/`params`
    // getters — a caller inspecting `command` should never get an exception.
    if (hasInterface && !interfaceIsAddress) {
      throw UnimplementedError(
        'Windows ping binds only by source address, not by interface name: '
        'pass a source IP address instead of the interface name "$interface".',
      );
    }
  }

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
    // Windows `ping` binds ONLY by source address (split args: `-S <address>`).
    // A bare interface name is rejected at construction, so by the time this
    // getter runs a non-empty selection is guaranteed to be an address.
    if (hasInterface) {
      params.add('-S');
      params.add(interface!);
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
