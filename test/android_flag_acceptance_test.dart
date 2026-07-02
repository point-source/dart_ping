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

  ProcessResult runToybox(List<String> params, {String host = loopback}) =>
      Process.runSync(
        toybox,
        ['ping', ...params, host],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );

  test('stock toybox ping accepts the full Android argument list', () {
    // Sourced from the SAME assembly code Batch 1 introduced — not a copy.
    final params =
        PingLinux(loopback, 1, 1, 2, 64, .ipv4, isAndroid: true).params;

    final result = runToybox(params);
    final stderr = result.stderr as String;

    expect(
      argParseRejection.hasMatch(stderr),
      isFalse,
      reason:
          'stock toybox rejected an Android flag at argument parsing.\n'
          'argv: ping ${params.join(' ')} $loopback\n'
          'exit: ${result.exitCode}\n'
          'stderr: $stderr',
    );
  });

  test('the IPv6 and interface-bound Android lists are also accepted', () {
    // The IPv6 list is built with a v6 host so the constructor's address-family
    // guard is satisfied; it is run against the v6 loopback ::1. The
    // interface-bound list splits `-I lo` into separate argv tokens (the same
    // fix that gave the other valued flags their own tokens).
    final v6 = (
      params: PingLinux('::1', 1, 1, 2, 64, .ipv6, isAndroid: true).params,
      host: '::1',
    );
    final iface = (
      params: PingLinux(
        loopback,
        1,
        1,
        2,
        64,
        .ipv4,
        isAndroid: true,
        interface: 'lo',
      ).params,
      host: loopback,
    );

    for (final variant in [v6, iface]) {
      final result = runToybox(variant.params, host: variant.host);
      final stderr = result.stderr as String;
      expect(
        argParseRejection.hasMatch(stderr),
        isFalse,
        reason:
            'stock toybox rejected an Android flag at argument parsing.\n'
            'argv: ping ${variant.params.join(' ')} ${variant.host}\n'
            'stderr: $stderr',
      );
    }
  });

  test('reintroducing the iputils-only -O/-n WOULD fail the check (control)', () {
    // The desktop-Linux list carries -O and -n, which stock toybox rejects as
    // unknown options. Running it proves the detector above actually fires on a
    // rejection — so a future change that reintroduced -O/-n (or any flag
    // toybox does not accept) turns the gate red, not silently green.
    final desktopParams =
        PingLinux(loopback, 1, 1, 2, 64, .ipv4, isAndroid: false).params;

    final result = runToybox(desktopParams);
    final stderr = result.stderr as String;

    expect(stderr, contains('Unknown option'));
    expect(argParseRejection.hasMatch(stderr), isTrue);
  });
}
