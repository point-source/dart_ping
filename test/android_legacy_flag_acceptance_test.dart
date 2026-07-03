@Tags(['legacy'])
library;

import 'dart:io';

import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// §spec:android-legacy-ci-gate — flag-acceptance half for the LEGACY dialect.
///
/// The sibling of `android_flag_acceptance_test.dart` (which pins the toybox
/// dialect). Proves a REAL legacy AOSP `external/ping` / `ping6` (2008-vintage
/// iputils) accepts every flag dart_ping assembles for a legacy Android image,
/// rather than restating Batch 1's dialect logic in code. The exact argument
/// list AND the chosen executable are sourced from [PingLinux] (`isLegacy: true`)
/// — never a hand-copied parallel list — and run against the real binary
/// targeting a LOOPBACK address, so no external-network ICMP round trip is
/// touched: the run only exercises the legacy binary's ARGUMENT PARSER. A flag
/// it would reject fails at argument parsing before the socket is opened, which
/// this gate catches.
///
/// A CONTROL case proves the mirror: reintroducing the `-4` / `-6` family flag
/// (which the legacy binary predates) IS rejected — so the Batch 1 detection
/// that keeps the family flag OFF the legacy command is verified against the
/// parser that actually rejects it, not merely asserted in code. Mirrors the
/// `-O` / `-n` control the toybox gate runs.
///
/// Tagged `legacy` so it runs only where a legacy binary is provisioned — the
/// dedicated `android-legacy` CI job (`dart test -t legacy`) that builds
/// legacy iputils `ping`/`ping6` first and points LEGACY_PING_BIN /
/// LEGACY_PING6_BIN at them. The fixture-driven parser assertions in
/// `android_legacy_output_parity_test.dart` need no binary and run in the normal
/// `dart test -x live` gate.
void main() {
  // The split legacy binaries. CI builds iputils (tag s20101006 — the lineage
  // that rejects `-4`/`-6` yet accepts `-W`/`-i`/`-t`/`-c`/`-I`, matching the
  // AOSP `external/ping`) and exports these; a local run can point them at any
  // legacy build. Defaults are the bare names so a developer with the binaries
  // on PATH can run `dart test -t legacy` directly.
  final legacyPing = Platform.environment['LEGACY_PING_BIN'] ?? 'ping';
  final legacyPing6 = Platform.environment['LEGACY_PING6_BIN'] ?? 'ping6';
  const loopback4 = '127.0.0.1';
  const loopback6 = '::1';

  // getopt in the legacy binary rejects a bad/absent flag BEFORE the socket is
  // opened, printing one of these:
  //   - `invalid option -- '<c>'`            — a flag the binary does not know
  //                                            (e.g. the reintroduced -4 / -6)
  //   - `unrecognized option '--<name>'`     — a long-form it does not know
  //   - `option requires an argument -- '<c>'` — a valued flag missing its value
  // A successful parse instead reaches the socket stage, which then fails for an
  // unrelated, environment-dependent reason on an unprivileged CI runner
  // (`ping: icmp open socket: Operation not permitted`) — NOT an argument
  // rejection. Keying on these parser messages makes "green" mean "the legacy
  // binary parsed our command" independently of whether loopback ICMP actually
  // succeeds on the runner.
  final argParseRejection = RegExp(
    r"invalid option|unrecognized option|option requires an argument",
    caseSensitive: false,
  );

  /// Picks the real binary for the executable [PingLinux] selected: a legacy
  /// IPv6 run dispatches to the separate `ping6` binary (§spec:android-legacy-dialect),
  /// so the gate must run the SAME executable dart_ping would launch.
  String binFor(PingLinux ping) =>
      ping.executable == 'ping6' ? legacyPing6 : legacyPing;

  ProcessResult run(String bin, List<String> params, String host) =>
      Process.runSync(
        bin,
        [...params, host],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );

  /// Runs the command [PingLinux] produces (its [PingLinux.executable] and
  /// [PingLinux.params]) against [host] (loopback) and asserts the legacy binary
  /// did NOT reject any flag at argument parsing.
  void expectAccepted(PingLinux ping, String host) {
    final result = run(binFor(ping), ping.params, host);
    final stderr = result.stderr as String;
    expect(
      argParseRejection.hasMatch(stderr),
      isFalse,
      reason:
          'legacy ${ping.executable} rejected a flag at argument parsing.\n'
          'argv: ${ping.executable} ${ping.params.join(' ')} $host\n'
          'exit: ${result.exitCode}\n'
          'stderr: $stderr',
    );
  }

  // The argv AND executable are sourced from the SAME dialect logic Batch 1
  // introduced (`isLegacy: true`) — never a hand-copied parallel list.
  // `isLegacy: true` is pinned so these assert the LEGACY command without
  // triggering the runtime dialect probe (a real `ping -4` subprocess whose
  // result would depend on the CI runner's own `ping`).

  test('legacy ping accepts the default flagless IPv4 argument list', () {
    // The default `Ping('google.com')` on a legacy image: NO `-4` family flag
    // (the legacy `ping` is physically IPv4-only and rejects `-4`), launched via
    // the `ping` executable.
    expectAccepted(
      PingLinux(
        loopback4, 1, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: true,
      ),
      loopback4,
    );
  });

  test('legacy ping6 accepts the IPv6 argument list', () {
    // IPv6 on a legacy image lives in a SEPARATE `ping6` binary, selected by the
    // executable override — with no `-6` family flag on the argv.
    final ping = PingLinux(
      loopback6, 1, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: true,
    );
    expect(ping.executable, 'ping6'); // classification produced the ping6 command
    expectAccepted(ping, loopback6);
  });

  test('legacy ping accepts the interface-bound IPv4 list', () {
    expectAccepted(
      PingLinux(
        loopback4,
        1,
        1,
        2,
        64,
        .ipv4,
        isAndroid: true,
        isLegacy: true,
        interface: 'lo',
      ),
      loopback4,
    );
  });

  test('reintroducing the -4 family flag WOULD fail on legacy ping (control)', () {
    // The toybox IPv4 command carries `-4` (which toybox accepts). Running that
    // same argv against the legacy `ping` proves the legacy binary rejects it —
    // so a future change that reintroduced the family flag on the legacy command
    // (undoing Batch 1's dialect selection) turns this gate red, not silently
    // green.
    final withFamilyFlag =
        PingLinux(
          loopback4, 1, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
        ).params;
    expect(withFamilyFlag, contains('-4')); // sanity: the control really re-adds it

    final stderr = run(legacyPing, withFamilyFlag, loopback4).stderr as String;
    expect(stderr, contains('invalid option'));
    expect(argParseRejection.hasMatch(stderr), isTrue);
  });

  test('reintroducing the -6 family flag WOULD fail on legacy ping6 (control)', () {
    // Symmetric control for IPv6: the toybox IPv6 command carries `-6`; the
    // legacy `ping6` (which predates the family flag) rejects it too.
    final withFamilyFlag =
        PingLinux(
          loopback6, 1, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: false,
        ).params;
    expect(withFamilyFlag, contains('-6'));

    final stderr = run(legacyPing6, withFamilyFlag, loopback6).stderr as String;
    expect(stderr, contains('invalid option'));
    expect(argParseRejection.hasMatch(stderr), isTrue);
  });
}
