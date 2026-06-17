import 'package:dart_ping/dart_ping.dart';
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
    final ping = PingLinux('host', 3, 1, 2, 64, false);

    test('params include the standard flags and the count', () {
      expect(
        ping.params,
        ['-O', '-n', '-W 2', '-i 1', '-t 64', '-c 3'],
      );
    });

    test('params omit -c when count is null', () {
      final unbounded = PingLinux('host', null, 1, 2, 64, false);
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
    final ping = PingMac('host', 3, 1, 2, 64, false);

    test('params scale the timeout to milliseconds and include the count', () {
      expect(ping.params, ['-n', '-W 2000', '-i 1', '-m 64', '-c 3']);
    });

    test('params omit -c when count is null', () {
      final unbounded = PingMac('host', null, 1, 2, 64, false);
      expect(unbounded.params, isNot(anyElement(startsWith('-c'))));
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
    final ping = PingWindows('host', 3, 1, 2, 64, false);

    test('params for a bounded IPv4 run use -n with the count', () {
      expect(ping.params, ['-w', '2000', '-i', '64', '-4', '-n', '3']);
    });

    test('params for an unbounded run use -t', () {
      final unbounded = PingWindows('host', null, 1, 2, 64, false);
      expect(unbounded.params, ['-w', '2000', '-i', '64', '-4', '-t']);
    });

    test('params throw for IPv6 (unsupported on Windows)', () {
      final ipv6 = PingWindows('host', 1, 1, 2, 64, true);
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
}
