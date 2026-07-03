import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';

class PingLinux extends BasePing implements Ping {
  /// Base unknown-host phrasings shared by both the iputils [defaultParser] and
  /// the toybox [androidParser]. Android extends this with `bad address` (its
  /// name-resolution failure), so keeping the base in one place makes that
  /// "base + Android extension" relationship explicit and drift-free.
  static const String _unknownHostPattern =
      r'unknown host|service not known|failure in name';

  static PingParser get defaultParser => .new(
    responseRgx: RegExp(
      r'bytes from (?:.*)(?<ip>\b(?:\d{1,3}\.){3}\d{1,3}\b)\)?: icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>\d+(?:\.\d+)?)',
    ),
    summaryRgx: RegExp(
      r'(?<tx>\d+) packets transmitted, (?<rx>\d+) received,.*time (?<time>\d+)ms',
    ),
    timeoutRgx: RegExp(r'no answer yet for icmp_seq=(?<seq>\d+)'),
    timeToLiveRgx: RegExp(
      r'From (?<ip>.*)(?:.*) icmp_seq=(?<seq>\d+) Time to live exceeded',
    ),
    unknownHostStr: RegExp(_unknownHostPattern),
    noRouteStrs: [
      RegExp(r'[Nn]etwork is unreachable'),
      RegExp(r'[Dd]estination [Hh]ost [Uu]nreachable'),
      RegExp(r'[Nn]o route to host'),
      RegExp(r'[Aa]ddress family for hostname not supported'),
    ],
  );

  /// One superset parser for BOTH Android dialects — stock toybox and legacy
  /// AOSP `external/ping` (§spec:android-output-parity,
  /// §spec:android-legacy-output-parity).
  ///
  /// Legacy output *is* iputils output, and toybox differs from it in only two
  /// patterns, so rather than route per dialect (a second place the dialect
  /// detection could be wrong) this parser's patterns are the UNION of both.
  /// The timeout and routing-error patterns are byte-compatible across both and
  /// the iputils [defaultParser], so those reuse [defaultParser]'s
  /// [timeoutRgx], [timeToLiveRgx], and [noRouteStrs] verbatim. The patterns
  /// that diverge are widened to cover both dialects:
  ///
  ///  - **Reply line.** The `ip` group captures an IPv4 dotted quad (the shared
  ///    iputils form) OR an IPv6 address, so a legacy `ping6` reply — or a
  ///    toybox `-6` reply — yields a per-probe [PingResponse], not just a
  ///    summary (§spec:android-legacy-output-parity). desktop Linux keeps the
  ///    IPv4-only [defaultParser].
  ///  - **Statistics line.** The legacy iputils line carries a trailing
  ///    wall-clock `time <n>ms`; toybox prints
  ///    `N packets transmitted, M received, X% packet loss` with NO trailing
  ///    total. [summaryRgx] makes that `time` group optional, so the summary's
  ///    `time` is populated on legacy and null on toybox (the field is already
  ///    nullable, so cross-platform consumers are unaffected). These
  ///    transmitted/received counts are authoritative on both dialects: neither
  ///    emits a per-lost-probe line, so a timed-out probe surfaces only as a
  ///    lower `received` + non-zero loss, never as a mid-run `requestTimedOut`
  ///    event.
  ///  - **Name-resolution failure.** The unknown-host set is the union of the
  ///    iputils phrasings (legacy: `unknown host`) and toybox's
  ///    `<host>: bad address` (via `xgetaddrinfo`).
  /// Built once and shared across every Android [PingLinux]: [PingParser.parse]
  /// is stateless (it only reads its patterns and returns a fresh event), so a
  /// single instance is safe to reuse concurrently and avoids rebuilding the
  /// regexes on each construction.
  static final PingParser androidParser = _buildAndroidParser();

  static PingParser _buildAndroidParser() {
    final iputils = defaultParser;

    return PingParser(
      // Superset reply pattern: identical to the iputils IPv4 form
      // (§spec:android-output-parity), but the `ip` group also captures an
      // IPv6 address so a legacy `ping6` reply — or a toybox `-6` reply —
      // yields a per-probe [PingResponse] instead of only a summary
      // (§spec:android-legacy-output-parity). The IPv4 alternative is tried
      // first so a dotted quad still captures byte-for-byte as before; the IPv6
      // alternative requires at least one `:` so it never swallows a hostname.
      // The leading `.*?` is lazy (not the iputils `.*`) so the `ip` group
      // anchors to the FULL address rather than backtracking to its last
      // colon-separated group on an IPv6 line. desktop Linux keeps the
      // IPv4-only iputils [defaultParser], unchanged.
      responseRgx: RegExp(
        r'bytes from (?:.*?)(?<ip>\b(?:\d{1,3}\.){3}\d{1,3}\b|[0-9a-fA-F:]*:[0-9a-fA-F:]*)\)?: icmp_seq=(?<seq>\d+) ttl=(?<ttl>\d+) time=(?<time>\d+(?:\.\d+)?)',
      ),
      // Superset statistics pattern matching BOTH dialects: the trailing
      // wall-clock `time <n>ms` is present on the legacy iputils line
      // (`… X% packet loss, time 3026ms`) and ABSENT on toybox, so the `time`
      // group is optional. On toybox it is null (already-nullable field), on
      // legacy it is populated (§spec:android-legacy-output-parity). These
      // transmitted/received counts are authoritative on both dialects: neither
      // emits a per-lost-probe line (`-O` is deliberately absent on Android), so
      // a timed-out probe surfaces only as a lower `received` + non-zero loss.
      summaryRgx: RegExp(
        r'(?<tx>\d+) packets transmitted, (?<rx>\d+) received(?:.*?\btime (?<time>\d+)ms)?',
      ),
      timeoutRgx: iputils.timeoutRgx,
      // The iputils TTL-exceeded pattern's `ip` group is `(?<ip>.*)`, which
      // already tolerates an IPv6 intermediate-hop address, so both dialects
      // reuse it verbatim.
      timeToLiveRgx: iputils.timeToLiveRgx,
      // Unknown-host set is the union of both dialects' name-resolution
      // failures: the iputils phrasings (legacy: `unknown host`) plus toybox's
      // `bad address`.
      unknownHostStr: RegExp('$_unknownHostPattern|bad address'),
      noRouteStrs: iputils.noRouteStrs,
    );
  }

  /// Whether this instance targets Android's toybox `ping` rather than desktop
  /// iputils `ping`. Injected as an explicit seam (defaulting to
  /// [Platform.isAndroid]) so both [params] and the default parser selection are
  /// unit-testable off-device.
  final bool isAndroid;

  /// Whether this Android image ships the **legacy AOSP `external/ping`** dialect
  /// rather than stock **toybox** (§spec:android-legacy-dialect). The two are
  /// mutually exclusive and diverge on three coupled axes: toybox is a single
  /// multicall `ping` that accepts `-4`/`-6`; legacy is a SPLIT `ping`
  /// (IPv4-only, which *rejects* `-4`/`-6` with `invalid option -- 4`) plus a
  /// separate `ping6` binary. So the launched command's family flag and its
  /// [executable] must be chosen per dialect — see [params] / [executable].
  ///
  /// Injected as an explicit seam (like [isAndroid]) so command selection is
  /// unit-testable off-device. When not injected it is resolved once, at
  /// construction, by [_detectLegacyDialect] — but only on Android; desktop
  /// Linux is never legacy and never probes.
  final bool isLegacy;

  /// Memoized result of the network-free dialect probe, so the classification is
  /// computed at most once per process and reused within a run rather than
  /// recomputed per probe (§spec:android-legacy-dialect — network-free,
  /// deterministic, stable within a run).
  static bool? _cachedLegacy;

  /// Classifies the running image's `ping` as legacy vs toybox by whether it
  /// **accepts the `-4`/`-6` family flag** — the axis the launched command must
  /// respect. Network-free and deterministic: it runs `ping -4` with NO target,
  /// so both dialects exit at argument validation before any ICMP is sent. A
  /// legacy `external/ping` rejects the family flag itself
  /// (`ping: invalid option -- '4'`); toybox accepts `-4` and instead complains
  /// about the missing operand, so the "invalid/unrecognized option" signature
  /// is what distinguishes them.
  ///
  /// The exact probe argv and its acceptance against real toybox / legacy
  /// binaries are pinned deterministically by §spec:android-legacy-ci-gate;
  /// here the contract is only that the classification keys off family-flag
  /// acceptance, is network-free, and is stable within a run. If the probe
  /// cannot run at all, it falls back to the toybox command (the #100 default),
  /// the safer assumption on a modern image.
  static bool _detectLegacyDialect() {
    final cached = _cachedLegacy;
    if (cached != null) return cached;

    var legacy = false;
    try {
      final result = Process.runSync(
        'ping',
        ['-4'],
        environment: {'LC_ALL': 'C'},
      );
      final out = '${result.stdout}${result.stderr}'.toLowerCase();
      legacy =
          out.contains('invalid option') || out.contains('unrecognized option');
    } on Object {
      legacy = false;
    }
    return _cachedLegacy = legacy;
  }

  @override
  Map<String, String> get locale => {'LC_ALL': 'C'};

  /// The executable to launch. On the **legacy** Android dialect an IPv6 run
  /// must launch the separate `ping6` binary, because the legacy `ping` is
  /// IPv4-only and cannot reach an IPv6 target (§spec:android-legacy-dialect).
  /// Every other case — toybox (single multicall `ping` family-pinned by
  /// `-4`/`-6`), legacy IPv4, and desktop Linux/macOS/Windows — launches the
  /// unified `ping`, so this override is byte-for-byte a no-op off the
  /// legacy-IPv6 path.
  @override
  String get executable =>
      isLegacy && ipVersion == .ipv6 ? 'ping6' : 'ping';

  @override
  List<String> get params {
    final args = [
      // Family flag selection is dialect-aware (§spec:android-legacy-dialect):
      //  - toybox / desktop Linux: keep the explicit `-4`/`-6` (#100), which
      //    pins the family EXCLUSIVELY on the single multicall `ping`. Dropping
      //    it would let a flagless toybox `ping` on a dual-stack host silently
      //    resolve over the other family, breaking
      //    §spec:ipv6-address-family-selector's exclusive-family contract.
      //  - legacy: omit it. The legacy `ping` is physically IPv4-only (family
      //    still exclusively pinned to IPv4 without the flag) and REJECTS the
      //    `-4` it would otherwise receive (`invalid option -- 4`); a legacy
      //    IPv6 run goes to the `ping6` [executable] instead, also flagless.
      if (!isLegacy) ipVersion.flag,
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
      // Each valued flag and its value are pushed as SEPARATE argv tokens, never
      // a glued `'-W $timeout'`. Process launch uses `Process.start` with no
      // shell, so a glued token reaches `ping` as ONE argument whose value
      // carries a leading space (e.g. `-W`'s value " 2"). iputils' `strtol`
      // tolerates that leading space, but Android's toybox `ping` does NOT for
      // its fractional `-i` argument — it rejects a glued `'-i 1'` with
      // `Not a number ' 1'` and aborts at argument parsing, so the default
      // Android run would STILL fail even after dropping `-O`/`-n`. Splitting
      // matches how `-I` (below) is already passed and is byte-identical for
      // iputils: the `command` string (params joined on spaces) is unchanged
      // (§spec:android-toybox-flags, verified against real toybox by
      // §spec:android-ci-gate).
      '-W', '$timeout',
      '-i', '$interval',
      '-t', '$ttl',
    ];
    if (count != null) args.addAll(['-c', '$count']);
    // Linux/Android `ping -I` binds either an interface name or a source
    // address. The flag and value are pushed as SEPARATE argv tokens for the
    // same reason as the valued flags above: a glued `'-I $interface'` token
    // would reach ping as one argument whose value carries a leading space
    // (e.g. interface " eth0"), and the bind would fail.
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
    bool? isLegacy,
  }) : this._(
         host,
         count,
         interval,
         timeout,
         ttl,
         ipVersion,
         // Resolve the platform ONCE here; the private constructor reuses the
         // result for both the `isAndroid` field and the default parser choice,
         // so `Platform.isAndroid` is never read twice.
         isAndroid ?? Platform.isAndroid,
         // Resolve the dialect ONCE, only on Android (desktop Linux is never
         // legacy and must never probe — the `&&` short-circuits). When the
         // caller injects `isLegacy` (the unit-test seam) the probe is skipped
         // entirely, keeping the classification off the live network.
         isLegacy ?? ((isAndroid ?? Platform.isAndroid) && _detectLegacyDialect()),
         parser: parser,
         encoding: encoding,
         interface: interface,
         nat64Synthesis: nat64Synthesis,
       );

  PingLinux._(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    IpVersion ipVersion,
    this.isAndroid,
    this.isLegacy, {
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
         // Select the superset Android parser on Android (it covers both the
         // toybox and legacy dialects — §spec:android-legacy-output-parity) and
         // the iputils parser on desktop Linux, unless the caller supplied a
         // custom one.
         parser ?? (isAndroid ? androidParser : defaultParser),
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
