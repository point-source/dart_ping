import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingMac extends BasePing implements Ping {
  static PingParser get defaultParser => .new(
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
    errorStrs: [RegExp(r'[Hh]ost is down')],
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
    // (§spec:address-family-error-honesty). iOS IPv6 is served by dart_ping's
    // own native Swift engine, not this subprocess path.
    if (ipVersion == .ipv6) {
      throw UnimplementedError(
        'IPv6 is not supported on macOS via dart_ping; use a hostname over '
        'IPv4 (iOS supports native IPv6 directly)',
      );
    }
    final args = ['-n', '-W ${timeout * 1000}', '-i $interval', '-m $ttl'];
    if (count != null) args.add('-c $count');
    // macOS binds a source address with `-S` and an interface name with `-b`
    // (boundif), so pick the flag from the value's classified form. The flag
    // and value are SEPARATE argv tokens — `Process.start` runs without a
    // shell, so a glued `'-S $interface'` token would reach ping as one
    // argument whose value carries a leading space and fail to bind.
    final interface = this.interface;
    if (interface != null && interface.isNotEmpty) {
      args.add(interfaceIsAddress ? '-S' : '-b');
      args.add(interface);
    }

    return args;
  }

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

  @override
  PingError? interpretExitCode(int exitCode) {
    // BSD `ping` reports "no echo reply" with TWO exit codes: `1` on pure
    // silence and `2` when the run drew ICMP errors back but no replies (the
    // classic `ttl=1` / TTL-exceeded case). Both are the same logical outcome,
    // so both map to a single recognized `noReply`. Because a recognized
    // exit-code error short-circuits base_ping's unmapped-exit throw path, the
    // already-assembled 100%-loss summary becomes the terminal event instead of
    // a thrown `Exception('Ping process exited with code: 2')`
    // (§spec:mac-all-timeout-summary).
    if (exitCode == 1 || exitCode == 2) {
      return PingError(.noReply);
    } else if (exitCode == 68) {
      return PingError(.unknownHost);
    }

    return null;
  }

  @override
  Exception? throwExit(int exitCode) {
    // Recognized codes (`1`/`2` no-reply, `68` unknown host) are handled by
    // interpretExitCode and must not surface a generic exit exception; every
    // other non-success code remains an unmapped throw so a genuinely unknown
    // failure still surfaces a catchable error then closes the stream
    // (§spec:stream-lifecycle-robustness — the guarantee narrows by exactly the
    // one well-understood exit `2`, it does not loosen).
    const recognized = {1, 2, 68};

    return exitCode != 0 && !recognized.contains(exitCode)
        ? Exception('Ping process exited with code: $exitCode')
        : null;
  }
}
