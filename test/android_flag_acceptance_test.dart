@Tags(['toybox'])
library;

import 'dart:io';

import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// §spec:android-ci-gate — flag-acceptance half.
///
/// Proves a REAL stock toybox `ping` accepts every flag dart_ping assembles for
/// Android, rather than restating Batch 1's allow-list in code. The exact
/// Android argument list — sourced from [PingLinux.params] (`isAndroid: true`),
/// never a hand-copied parallel list — is run against an installed toybox
/// `ping` targeting a LOOPBACK address, so no external-network ICMP round trip
/// is touched: the run only exercises toybox's ARGUMENT PARSER. A flag toybox
/// would reject fails at argument parsing before the socket is opened, which
/// this gate catches.
///
/// Tagged `toybox` so it runs only where a toybox binary is installed — the
/// dedicated `android-toybox` CI job (`dart test -t toybox`) that installs
/// toybox first. The fixture-driven parser assertions in
/// `android_output_parity_test.dart` need no binary and run in the normal
/// `dart test -x live` gate.
void main() {
  // The toybox multicall binary. CI puts `toybox` on PATH (apt); a local dev
  // run can point at a build with TOYBOX_BIN=/path/to/toybox.
  final toybox = Platform.environment['TOYBOX_BIN'] ?? 'toybox';
  const loopback = '127.0.0.1';

  // toybox's option parser (lib/args.c) rejects a bad flag BEFORE `ping` opens
  // its socket, printing one of these to stderr:
  //   - `Unknown option '<c>'`   — a flag toybox does not know (e.g. -O / -n)
  //   - `Not a number '<v>'`     — a bad numeric value, e.g. the glued `-i 1`
  //                                (leading space) toybox's fractional parser
  //                                rejects — the reason dart_ping splits each
  //                                valued flag into separate argv tokens
  //   - `Needs argument`         — a required option value is missing
  // A successful parse instead reaches the network/socket stage, which may then
  // fail for an unrelated, environment-dependent reason (e.g. unprivileged ICMP
  // being blocked on the CI host — `socket ...: Permission denied`), which is
  // NOT an argument rejection. Keying on these parser messages makes "green"
  // mean "toybox parsed our arguments" independently of whether loopback ICMP
  // actually succeeds on the runner.
  final argParseRejection = RegExp(
    r"Unknown option|Not a number|Needs argument",
  );

  ProcessResult runToybox(List<String> params, String host) => Process.runSync(
    toybox,
    ['ping', ...params, host],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );

  /// Runs [params] against toybox `ping` on [host] (loopback) and asserts
  /// toybox did NOT reject any flag at argument parsing.
  void expectAccepted(List<String> params, {String host = loopback}) {
    final result = runToybox(params, host);
    final stderr = result.stderr as String;
    expect(
      argParseRejection.hasMatch(stderr),
      isFalse,
      reason:
          'stock toybox rejected an Android flag at argument parsing.\n'
          'argv: ping ${params.join(' ')} $host\n'
          'exit: ${result.exitCode}\n'
          'stderr: $stderr',
    );
  }

  // The argument lists are sourced from the SAME assembly code Batch 1
  // introduced (PingLinux.params) — never a hand-copied parallel list.
  // `isLegacy: false` is pinned so these assert the TOYBOX argument list
  // without triggering the runtime dialect probe (a real `ping -4` subprocess
  // whose result would depend on the CI runner's own `ping`).
  test('stock toybox ping accepts the default IPv4 Android argument list', () {
    expectAccepted(
      PingLinux(
        loopback, 1, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
      ).params,
    );
  });

  test('stock toybox ping accepts the IPv6 Android argument list', () {
    // Built with a v6 host so the constructor's address-family guard is
    // satisfied, then run against the v6 loopback ::1.
    expectAccepted(
      PingLinux(
        '::1', 1, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: false,
      ).params,
      host: '::1',
    );
  });

  test('stock toybox ping accepts the interface-bound Android list', () {
    // `-I lo` is split into separate argv tokens (the same fix that gave the
    // other valued flags their own tokens).
    expectAccepted(
      PingLinux(
        loopback,
        1,
        1,
        2,
        64,
        .ipv4,
        isAndroid: true,
        isLegacy: false,
        interface: 'lo',
      ).params,
    );
  });

  test('reintroducing the iputils-only -O/-n WOULD fail the check (control)', () {
    // The desktop-Linux list carries -O and -n, which stock toybox rejects as
    // unknown options. Running it proves the detector above actually fires on a
    // rejection — so a future change that reintroduced -O/-n (or any flag
    // toybox does not accept) turns the gate red, not silently green.
    final desktopParams =
        PingLinux(loopback, 1, 1, 2, 64, .ipv4, isAndroid: false).params;

    final stderr = runToybox(desktopParams, loopback).stderr as String;

    expect(stderr, contains('Unknown option'));
    expect(argParseRejection.hasMatch(stderr), isTrue);
  });
}
