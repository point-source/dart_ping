import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingLinux extends BasePing implements Ping {
  static PingParser get defaultParser => .new(
    responseRgx: RegExp(
      r'bytes from (?:.*)(?<ip>\b(?:\d{1,3}\.){3}\d{1,3}\b)\)?: icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>(\d+).?(\d+))',
    ),
    summaryRgx: RegExp(
      r'(?<tx>\d+) packets transmitted, (?<rx>\d+) received,.*time (?<time>\d+)ms',
    ),
    timeoutRgx: RegExp(r'no answer yet for icmp_seq=(?<seq>\d+)'),
    timeToLiveRgx: RegExp(
      r'From (?<ip>.*)(?:.*) icmp_seq=(?<seq>\d+) Time to live exceeded',
    ),
    unknownHostStr: RegExp(r'unknown host|service not known|failure in name'),
    noRouteStrs: [
      RegExp(r'[Nn]etwork is unreachable'),
      RegExp(r'[Dd]estination [Hh]ost [Uu]nreachable'),
      RegExp(r'[Nn]o route to host'),
      RegExp(r'[Aa]ddress family for hostname not supported'),
    ],
  );

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  @override
  List<String> get params {
    final args = [
      ipVersion.flag,
      '-O',
      '-n',
      '-W $timeout',
      '-i $interval',
      '-t $ttl',
    ];
    if (count != null) args.add('-c $count');
    // Linux/Android `ping -I` binds either an interface name or a source
    // address. The flag and value are pushed as SEPARATE argv tokens: process
    // launch uses `Process.start` with no shell, so a glued `'-I $interface'`
    // token would reach ping as one argument whose value carries a leading
    // space (e.g. interface " eth0"), and the bind would fail.
    final interface = this.interface;
    if (interface != null && interface.isNotEmpty) {
      args.add('-I');
      args.add(interface);
    }

    return args;
  }

  PingLinux(
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
    return exitCode == 1 ? PingError(.noReply) : null;
  }

  @override
  Exception? throwExit(int exitCode) {
    return exitCode > 1
        ? Exception('Ping process exited with code: $exitCode')
        : null;
  }
}
