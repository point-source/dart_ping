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
    IpVersion ipVersion, {
    PingParser? parser,
    Encoding encoding = const Utf8Codec(),
    String? interface,
    bool nat64Synthesis = true,
  }) : super(
          host,
          count,
          interval,
          timeout,
          ttl,
          ipVersion,
          parser ?? defaultParser,
          encoding,
          false,
          interface,
          nat64Synthesis,
        );

  static PingParser get defaultParser => PingParser(
        responseRgx: RegExp(
          r'bytes from (?<ip>.*): icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>(\d+).?(\d+))',
        ),
        summaryRgx: RegExp(
          r'(?<tx>\d+) packets transmitted, (?<rx>\d+) packets received',
        ),
        timeoutRgx: RegExp(r'Request timeout for icmp_seq (?<seq>\d+)'),
        timeToLiveRgx: RegExp(r'from (?<ip>.*): Time to live exceeded'),
        unknownHostStr: RegExp(r'Unknown host'),
        noRouteStrs: [
          RegExp(r'[Nn]o route to host'),
          RegExp(r'[Nn]etwork is unreachable'),
          // Family-unavailable failures, matching the Linux parser's coverage
          // so cross-platform code can branch on noRoute consistently (#69).
          RegExp(r'[Aa]ddress family .*not supported'),
        ],
        // "Host is down" (EHOSTDOWN) is a host-liveness condition, not a
        // routing/address-family failure, so it is NOT a noRoute; it falls
        // through to the catch-all unknown rather than being mislabelled.
        errorStrs: [
          RegExp(r'[Hh]ost is down'),
        ],
      );

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  @override
  List<String> get params {
    // macOS IPv6 is not supported on the subprocess path: the IPv4-only
    // `/sbin/ping` rejects an IPv6 target, while the legacy `ping6` binary
    // takes different flags (no `-W`/`-m`) and emits a different output format
    // (`hlim=` rather than `ttl=`) that this parser does not handle. Surface an
    // explicit, honest error rather than a misleading generic process failure
    // (§spec:address-family-error-honesty). iOS IPv6 is served by the native
    // Swift engine in dart_ping_ios.
    if (ipVersion == IpVersion.ipv6) {
      throw UnimplementedError(
        'IPv6 is not supported on macOS via dart_ping; use a hostname over '
        'IPv4, or dart_ping_ios for native iOS IPv6',
      );
    }
    var params = ['-n', '-W ${timeout * 1000}', '-i $interval', '-m $ttl'];
    if (count != null) params.add('-c $count');
    // macOS binds a source address with `-S` and an interface name with `-b`
    // (boundif), so pick the flag from the value's classified form. The flag
    // and value are SEPARATE argv tokens — `Process.start` runs without a
    // shell, so a glued `'-S $interface'` token would reach ping as one
    // argument whose value carries a leading space and fail to bind.
    if (hasInterface) {
      params.add(interfaceIsAddress ? '-S' : '-b');
      params.add(interface!);
    }

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
