import 'dart:convert';
import 'dart:io';

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

  /// Parser for Android's stock toybox `ping` (§spec:android-output-parity).
  ///
  /// Android ships toybox rather than iputils `ping`. Its reply-line grammar,
  /// timeout handling, and routing-error phrasings are byte-compatible with the
  /// iputils patterns, so this parser reuses [defaultParser]'s [responseRgx],
  /// [timeoutRgx], [timeToLiveRgx], and [noRouteStrs] verbatim. Only the two
  /// patterns toybox actually phrases differently are overridden:
  ///
  ///  - **Statistics line.** toybox prints
  ///    `N packets transmitted, M received, X% packet loss` with NO trailing
  ///    `time <n>ms` (iputils appends the wall-clock total; toybox does not), so
  ///    [summaryRgx] omits the `time` group. The terminal summary's `time` is
  ///    therefore null on Android — every other field is populated, and the
  ///    field is already nullable, so cross-platform consumers are unaffected.
  ///    These transmitted/received counts are authoritative: toybox emits no
  ///    per-lost-probe line, so a timed-out probe surfaces only as a lower
  ///    `received` + non-zero loss in this line, never as a mid-run
  ///    `requestTimedOut` event (§spec:android-output-parity).
  ///  - **Name-resolution failure.** toybox reports it as `<host>: bad address`
  ///    (via `xgetaddrinfo`), which the iputils [unknownHostStr] would miss, so
  ///    `bad address` is added to the unknown-host alternatives.
  static PingParser get androidParser {
    final iputils = defaultParser;

    return PingParser(
      responseRgx: iputils.responseRgx,
      summaryRgx: RegExp(
        r'(?<tx>\d+) packets transmitted, (?<rx>\d+) received',
      ),
      timeoutRgx: iputils.timeoutRgx,
      timeToLiveRgx: iputils.timeToLiveRgx,
      unknownHostStr: RegExp(
        r'unknown host|service not known|failure in name|bad address',
      ),
      noRouteStrs: iputils.noRouteStrs,
    );
  }

  /// Whether this instance targets Android's toybox `ping` rather than desktop
  /// iputils `ping`. Injected as an explicit seam (defaulting to
  /// [Platform.isAndroid]) so both [params] and the default parser selection are
  /// unit-testable off-device.
  final bool isAndroid;

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  @override
  List<String> get params {
    final args = [
      ipVersion.flag,
      // `-O` (report outstanding/overdue replies) and `-n` (numeric output, no
      // reverse DNS) are iputils-only. Android's toybox `ping` rejects them as
      // unknown options and aborts at argument parsing with exit 2 — the #100
      // bug — before any ICMP is sent. toybox needs neither: it emits no
      // overdue-reply line and prints numeric addresses by default. Desktop
      // Linux keeps them byte-for-byte to preserve its live per-probe timeout
      // events (`timeoutRgx`) and reverse-DNS suppression
      // (§spec:android-toybox-flags).
      if (!isAndroid) '-O',
      if (!isAndroid) '-n',
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
    bool? isAndroid,
  }) : isAndroid = isAndroid ?? Platform.isAndroid,
       super(
         host,
         count,
         interval,
         timeout,
         ttl,
         ipVersion,
         // Select the toybox parser on Android and the iputils parser on desktop
         // Linux, unless the caller supplied a custom one. Resolved from the
         // parameter (the field is not yet assigned in the initializer list).
         parser ??
             ((isAndroid ?? Platform.isAndroid)
                 ? androidParser
                 : defaultParser),
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
