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

    test('interface name appends -I <name>', () {
      final named = PingLinux('host', 3, 1, 2, 64, false, interface: 'eth0');
      expect(named.params, contains('-I eth0'));
      expect(named.command, contains('-I eth0'));
    });

    test('interface address appends -I <address>', () {
      final addr =
          PingLinux('host', 3, 1, 2, 64, false, interface: '192.168.1.5');
      expect(addr.params, contains('-I 192.168.1.5'));
      expect(addr.command, contains('-I 192.168.1.5'));
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: the pre-feature params/command must be
      // identical whether `interface` is unset or explicitly null.
      const expected = ['-O', '-n', '-W 2', '-i 1', '-t 64', '-c 3'];
      final nullIface = PingLinux('host', 3, 1, 2, 64, false, interface: null);
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(anyElement(startsWith('-I'))));
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

    test('interface name appends -b <name> (boundif)', () {
      final named = PingMac('host', 3, 1, 2, 64, false, interface: 'en0');
      expect(named.params, contains('-b en0'));
      expect(named.command, contains('-b en0'));
      expect(named.params, isNot(contains('-S en0')));
    });

    test('interface address appends -S <address>', () {
      final addr =
          PingMac('host', 3, 1, 2, 64, false, interface: '192.168.1.5');
      expect(addr.params, contains('-S 192.168.1.5'));
      expect(addr.command, contains('-S 192.168.1.5'));
      expect(addr.params, isNot(contains('-b 192.168.1.5')));
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: pre-feature params/command unchanged.
      const expected = ['-n', '-W 2000', '-i 1', '-m 64', '-c 3'];
      final nullIface = PingMac('host', 3, 1, 2, 64, false, interface: null);
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(anyElement(startsWith('-S'))));
      expect(ping.params, isNot(anyElement(startsWith('-b'))));
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

    test('interface address appends split -S <address> args', () {
      final addr =
          PingWindows('host', 3, 1, 2, 64, false, interface: '192.168.1.5');
      expect(addr.params, containsAllInOrder(['-S', '192.168.1.5']));
      expect(addr.command, contains('-S 192.168.1.5'));
    });

    test('bare interface name is rejected with a catchable error', () {
      final named = PingWindows('host', 3, 1, 2, 64, false, interface: 'eth0');
      // Windows `ping` binds only by source address (`-S <address>`), never by
      // interface name, so a bare name must fail loudly rather than silently
      // ping the default route. Reading `.params`/`.command` throws.
      expect(() => named.params, throwsA(isA<UnimplementedError>()));
      expect(() => named.command, throwsA(isA<UnimplementedError>()));
      expect(
        () => named.params,
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('source address'), contains('interface name')),
          ),
        ),
      );
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: pre-feature params/command unchanged.
      const expected = ['-w', '2000', '-i', '64', '-4', '-n', '3'];
      final nullIface =
          PingWindows('host', 3, 1, 2, 64, false, interface: null);
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(contains('-S')));
    });
  });
}
