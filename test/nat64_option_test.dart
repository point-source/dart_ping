import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

/// Coverage for the cross-platform `nat64Synthesis` option surface on the
/// subprocess platform classes (§spec:nat64-tests).
///
/// The option is default-on and threaded onto `BasePing.nat64Synthesis`, but on
/// the subprocess platforms (Linux/Android, macOS, Windows) it is an inert
/// NO-OP: it carries the option for cross-platform parity yet must NOT alter
/// `params` or `command`. These tests construct each platform class directly —
/// the same style as `platform_test.dart` — so they exercise every platform on
/// any host without spawning a process.
void main() {
  group('PingLinux', () {
    test('nat64Synthesis defaults to enabled when the option is omitted', () {
      final ping = PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4);
      expect(ping.nat64Synthesis, isTrue);
    });

    test('nat64Synthesis threads the supplied value (true / false)', () {
      final enabled =
          PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: true);
      final disabled =
          PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: false);
      expect(enabled.nat64Synthesis, isTrue);
      expect(disabled.nat64Synthesis, isFalse);
    });

    test('the option is an inert NO-OP: params/command are byte-for-byte equal',
        () {
      // Backward-compat guard: whether the option is omitted (default),
      // explicitly true, or explicitly false, the spawned command must be
      // identical — proving the subprocess option never touches the raw path.
      final baseline = PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4);
      final enabled =
          PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: true);
      final disabled =
          PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: false);
      expect(enabled.params, baseline.params);
      expect(enabled.command, baseline.command);
      expect(disabled.params, baseline.params);
      expect(disabled.command, baseline.command);
    });
  });

  group('PingMac', () {
    test('nat64Synthesis defaults to enabled when the option is omitted', () {
      final ping = PingMac('host', 3, 1, 2, 64, IpVersion.ipv4);
      expect(ping.nat64Synthesis, isTrue);
    });

    test('nat64Synthesis threads the supplied value (true / false)', () {
      final enabled =
          PingMac('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: true);
      final disabled =
          PingMac('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: false);
      expect(enabled.nat64Synthesis, isTrue);
      expect(disabled.nat64Synthesis, isFalse);
    });

    test('the option is an inert NO-OP: params/command are byte-for-byte equal',
        () {
      final baseline = PingMac('host', 3, 1, 2, 64, IpVersion.ipv4);
      final enabled =
          PingMac('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: true);
      final disabled =
          PingMac('host', 3, 1, 2, 64, IpVersion.ipv4, nat64Synthesis: false);
      expect(enabled.params, baseline.params);
      expect(enabled.command, baseline.command);
      expect(disabled.params, baseline.params);
      expect(disabled.command, baseline.command);
    });
  });

  group('PingWindows', () {
    // Windows rejects bare interface names, so these cases stay on
    // IpVersion.ipv4 with no interface to construct cleanly.
    test('nat64Synthesis defaults to enabled when the option is omitted', () {
      final ping = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4);
      expect(ping.nat64Synthesis, isTrue);
    });

    test('nat64Synthesis threads the supplied value (true / false)', () {
      final enabled = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4,
          nat64Synthesis: true);
      final disabled = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4,
          nat64Synthesis: false);
      expect(enabled.nat64Synthesis, isTrue);
      expect(disabled.nat64Synthesis, isFalse);
    });

    test('the option is an inert NO-OP: params/command are byte-for-byte equal',
        () {
      final baseline = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4);
      final enabled = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4,
          nat64Synthesis: true);
      final disabled = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4,
          nat64Synthesis: false);
      expect(enabled.params, baseline.params);
      expect(enabled.command, baseline.command);
      expect(disabled.params, baseline.params);
      expect(disabled.command, baseline.command);
    });
  });
}
