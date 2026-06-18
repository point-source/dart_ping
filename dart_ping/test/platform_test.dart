import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/base_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

/// Coverage for the OS-specific getters (`params`, `locale`, `command`,
/// `interpretExitCode`, `throwExit`). These are pure functions of the
/// instance's fields, so instantiating each platform class directly exercises
/// them on **any** host — the `Ping()` factory would otherwise only ever build
/// the class matching `Platform.operatingSystem`, leaving the other two
/// platforms' getters unreached on a single-OS test run (#77).
void main() {
  group('PingLinux', () {
    final ping = PingLinux('host', 3, 1, 2, 64, IpVersion.ipv4);

    test('params force IPv4 with -4 and include the standard flags + count', () {
      expect(
        ping.params,
        ['-4', '-O', '-n', '-W 2', '-i 1', '-t 64', '-c 3'],
      );
    });

    test('params force IPv6 with -6', () {
      final v6 = PingLinux('host', 3, 1, 2, 64, IpVersion.ipv6);
      expect(v6.params.first, '-6');
    });

    test('executable is the unified ping for both families (not ping6)', () {
      expect(ping.executable, 'ping');
      expect(PingLinux('host', 3, 1, 2, 64, IpVersion.ipv6).executable, 'ping');
    });

    test('params omit -c when count is null', () {
      final unbounded = PingLinux('host', null, 1, 2, 64, IpVersion.ipv4);
      expect(unbounded.params, isNot(contains('-c null')));
      expect(unbounded.params, isNot(anyElement(startsWith('-c'))));
    });

    test('locale forces the C locale', () {
      expect(ping.locale, {'LC_ALL': 'C'});
    });

    test('command renders the full ping invocation', () {
      expect(ping.command, 'ping ${ping.params.join(' ')} host');
    });

    test('interpretExitCode: 1 is noReply, others are null', () {
      expect(ping.interpretExitCode(1)?.error, ErrorType.noReply);
      expect(ping.interpretExitCode(0), isNull);
      expect(ping.interpretExitCode(2), isNull);
    });

    test('throwExit only for codes greater than 1', () {
      expect(ping.throwExit(2), isA<Exception>());
      expect(ping.throwExit(1), isNull);
      expect(ping.throwExit(0), isNull);
    });
  });

  group('PingMac', () {
    final ping = PingMac('host', 3, 1, 2, 64, IpVersion.ipv4);

    test('params scale the timeout to milliseconds and include the count', () {
      expect(ping.params, ['-n', '-W 2000', '-i 1', '-m 64', '-c 3']);
    });

    test('params omit -c when count is null', () {
      final unbounded = PingMac('host', null, 1, 2, 64, IpVersion.ipv4);
      expect(unbounded.params, isNot(anyElement(startsWith('-c'))));
    });

    test('params throw for IpVersion.ipv6 (unsupported on the macOS path)', () {
      final ipv6 = PingMac('host', 1, 1, 2, 64, IpVersion.ipv6);
      expect(() => ipv6.params, throwsUnimplementedError);
    });

    test('locale forces the C locale', () {
      expect(ping.locale, {'LC_ALL': 'C'});
    });

    test('interpretExitCode maps 1/68 and ignores the rest', () {
      expect(ping.interpretExitCode(1)?.error, ErrorType.noReply);
      expect(ping.interpretExitCode(68)?.error, ErrorType.unknownHost);
      expect(ping.interpretExitCode(0), isNull);
      expect(ping.interpretExitCode(2), isNull);
    });

    test('throwExit ignores 1 and 68 but throws for other failures', () {
      expect(ping.throwExit(2), isA<Exception>());
      expect(ping.throwExit(68), isNull);
      expect(ping.throwExit(1), isNull);
    });
  });

  group('PingWindows', () {
    final ping = PingWindows('host', 3, 1, 2, 64, IpVersion.ipv4);

    test('params for a bounded IPv4 run use -n with the count', () {
      expect(ping.params, ['-w', '2000', '-i', '64', '-4', '-n', '3']);
    });

    test('params for an unbounded run use -t', () {
      final unbounded = PingWindows('host', null, 1, 2, 64, IpVersion.ipv4);
      expect(unbounded.params, ['-w', '2000', '-i', '64', '-4', '-t']);
    });

    test('params throw for IpVersion.ipv6 (unsupported on Windows)', () {
      final ipv6 = PingWindows('host', 1, 1, 2, 64, IpVersion.ipv6);
      expect(() => ipv6.params, throwsUnimplementedError);
    });

    test('locale requests en_US', () {
      expect(ping.locale, {'LANG': 'en_US'});
    });

    test('interpretExitCode always yields an unknown error with the code', () {
      final error = ping.interpretExitCode(5);
      expect(error?.error, ErrorType.unknown);
      expect(error?.message, contains('5'));
    });

    test('throwExit always returns an Exception carrying the code', () {
      expect(ping.throwExit(5).toString(), contains('5'));
    });
  });

  group('IpVersion selection', () {
    test('the selected family is threaded through each platform class', () {
      for (final v in IpVersion.values) {
        expect(PingLinux('host', 1, 1, 2, 64, v).ipVersion, v);
        expect(PingMac('host', 1, 1, 2, 64, v).ipVersion, v);
        expect(PingWindows('host', 1, 1, 2, 64, v).ipVersion, v);
      }
    });

    test('the Ping factory defaults to IpVersion.ipv4', () {
      // The factory builds the class for the current host; every core platform
      // class extends BasePing, which exposes the resolved family.
      expect((Ping('host') as BasePing).ipVersion, IpVersion.ipv4);
    });
  });

  group('Direct construction enforces the address-family guard', () {
    // The literal/family mismatch guard must fire on direct platform-class
    // construction too, not only via the Ping(...) factory (#69).
    test('PingLinux with an IPv6 literal + ipv4 throws ArgumentError', () {
      expect(
        () => PingLinux('::1', 1, 1, 2, 64, IpVersion.ipv4),
        throwsArgumentError,
      );
    });

    test('PingMac with an IPv4 literal + ipv6 throws ArgumentError', () {
      expect(
        () => PingMac('1.2.3.4', 1, 1, 2, 64, IpVersion.ipv6),
        throwsArgumentError,
      );
    });

    test('a matching literal constructs normally', () {
      expect(
        () => PingLinux('127.0.0.1', 1, 1, 2, 64, IpVersion.ipv4),
        returnsNormally,
      );
    });
  });
}
