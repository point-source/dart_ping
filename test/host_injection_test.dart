import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

/// Host command-injection safety (#90).
///
/// The guard is synchronous validation over a `host` string, so the injection
/// vector and the rejection rule are exercisable without spawning a process or a
/// shell — network-free and deterministic on every runner, including the Linux
/// CI host where no `cmd.exe` exists (§spec:host-injection-tests).
void main() {
  // Representative metacharacter payloads from the spec — each would break out
  // of `cmd.exe` on the Windows `forceCodepage` path if it reached the shell.
  final metacharHosts = <String>[
    '8.8.8.8&calc',
    'x|whoami',
    'a>b',
    'a^b',
    'a<b',
    r'a$b',
    'a;b',
    'a(b)c',
    'a`b`c',
    r'a\b',
    'a b', // whitespace
    'a\tb', // control character (tab)
    'a\nb', // control character (newline)
    '%VAR%', // bare percent (cmd.exe variable expansion)
    '8.8.8.8%calc', // free-standing `%` that is not a valid IPv6 zone
    'fe80::1%a&b', // scoped IPv6 with a metacharacter in the zone id
    'fe80::1%a;b', // scoped IPv6 with a metacharacter in the zone id
    'a${'b' * 64}.com', // label longer than the 63-char limit
  ];

  // Hosts that must keep working byte-for-byte after the fix.
  const validHosts = <String>[
    'example.com',
    'sub.example.com',
    'localhost',
    'my-host_1.internal',
    'a-b.example.com', // interior hyphen must keep passing
    'xn--nxasmq6b.example.com', // punycode / IDN
    'example.com.', // FQDN trailing dot
    '8.8.8.8',
    '127.0.0.1',
  ];

  // Hosts shaped like a `ping` option flag. They contain no shell metacharacter,
  // but `host` is handed to the subprocess as an argument, so a leading-dash
  // value would be read as a flag rather than a target (argument injection). No
  // valid hostname (RFC 952/1123 labels start alphanumeric) or IP literal starts
  // or ends with a hyphen, so these are refused (§spec:host-input-is-data).
  const optionFlagHosts = <String>[
    '-f',
    '-c1000000',
    '--flood',
    '-foo.com', // leading-dash label
    'foo-.com', // trailing-dash label
    '-', // bare hyphen
  ];

  // Bracketed IPv6 is URL authority notation, not a bare ping target; the
  // unbracketed literal is the supported form. Deliberately rejected.
  const bracketedHosts = <String>['[::1]', '[fe80::1%eth0]', '[2001:db8::1]'];

  group('Host injection safety (#90): ', () {
    group('validateHostSafety rejects metacharacter / unsafe hosts', () {
      for (final host in metacharHosts) {
        test('rejects ${host.replaceAll('\n', r'\n').replaceAll('\t', r'\t')}',
            () {
          expect(() => validateHostSafety(host), throwsArgumentError);
          expect(isHostSafe(host), isFalse);
        });
      }

      test('rejects an empty host', () {
        expect(() => validateHostSafety(''), throwsArgumentError);
      });
    });

    group('rejects option-flag-shaped hosts (argument injection)', () {
      for (final host in optionFlagHosts) {
        test('rejects $host', () {
          expect(() => validateHostSafety(host), throwsArgumentError);
          expect(isHostSafe(host), isFalse);
        });
      }

      test('Ping(-f) factory rejected before the stream starts', () {
        expect(() => Ping('-f'), throwsArgumentError);
      });
    });

    group('rejects bracketed IPv6 (use the unbracketed literal instead)', () {
      for (final host in bracketedHosts) {
        test('rejects $host', () {
          expect(() => validateHostSafety(host), throwsArgumentError);
          expect(isHostSafe(host), isFalse);
        });
      }

      test('the unbracketed literal IS accepted', () {
        expect(isHostSafe('::1'), isTrue);
        expect(isHostSafe('fe80::1%eth0'), isTrue);
      });
    });

    group('validateHostSafety accepts valid hostnames and IP literals', () {
      for (final host in validHosts) {
        test('accepts $host', () {
          expect(() => validateHostSafety(host), returnsNormally);
          expect(isHostSafe(host), isTrue);
        });
      }

      test('accepts IPv6 literals (selected with ipv6)', () {
        // Family matching is enforced separately; here we only assert host
        // SAFETY, so test the safety guard directly for IPv6 literals. Scoped
        // IPv6 with a named or numeric zone must be accepted DETERMINISTICALLY —
        // independent of whether the zone names a real interface on this host.
        for (final host in const [
          '::1',
          '2001:db8::1',
          '::ffff:1.2.3.4', // IPv4-mapped IPv6
          'fe80::1%eth0', // named zone
          'fe80::1%12', // numeric zone
        ]) {
          expect(() => validateHostSafety(host), returnsNormally, reason: host);
          expect(isHostSafe(host), isTrue, reason: host);
        }
      });

      test('accepts a maximum-length (63-char) label', () {
        final host = 'a${'b' * 62}.com'; // 63-char label
        expect(() => validateHostSafety(host), returnsNormally);
        expect(isHostSafe(host), isTrue);
      });
    });

    // The guard is shared Dart over a pure input, so rejection is independent of
    // the host platform and of `forceCodepage`. We prove this by constructing
    // the Windows platform class DIRECTLY — it runs on the Linux CI host — for
    // both flag values, plus through the public `Ping(...)` factory.
    group('rejection is independent of platform and forceCodepage', () {
      for (final host in const ['8.8.8.8&calc', 'x|whoami', 'a>b', 'a^b']) {
        for (final forceCodepage in const [false, true]) {
          test('PingWindows($host) rejected with forceCodepage: $forceCodepage',
              () {
            expect(
              () => PingWindows(
                host,
                1,
                1,
                2,
                255,
                IpVersion.ipv4,
                forceCodepage: forceCodepage,
              ),
              throwsArgumentError,
            );
          });
        }

        test('Ping($host) factory rejected before the stream starts', () {
          expect(() => Ping(host), throwsArgumentError);
        });
      }
    });

    // §spec:forcecodepage-injection-closed — a metacharacter host on the
    // forceCodepage path produces NO launchable ping command: construction
    // throws, so the dangerous value never reaches `command` / `params`.
    group('forceCodepage path builds no command for a metacharacter host', () {
      for (final host in const ['8.8.8.8&calc', 'x|whoami', 'a>b', 'a^b']) {
        test('no command/params are ever constructed for $host', () {
          // The throw happens in the CONSTRUCTOR, so no `PingWindows` instance
          // exists and `command` / `params` are never reachable with the
          // dangerous value — the host cannot transit `chcp 437 && ping …`.
          expect(
            () => PingWindows(
              host,
              1,
              1,
              2,
              255,
              IpVersion.ipv4,
              forceCodepage: true,
            ),
            throwsArgumentError,
          );
        });
      }
    });

    // Regression guard: legitimate hosts — including the forceCodepage happy
    // path — produce the SAME command/params as before the fix.
    group('legitimate hosts are unaffected (byte-for-byte command/params)', () {
      test('IPv4 literal, default flags', () {
        final ping = PingWindows('8.8.8.8', 1, 1, 2, 255, IpVersion.ipv4);
        expect(ping.params, ['-w', '2000', '-i', '255', '-4', '-n', '1']);
        expect(ping.command, 'ping -w 2000 -i 255 -4 -n 1 8.8.8.8');
      });

      test('hostname, default flags', () {
        final ping = PingWindows('example.com', 1, 1, 2, 255, IpVersion.ipv4);
        expect(ping.command, 'ping -w 2000 -i 255 -4 -n 1 example.com');
      });

      test('forceCodepage happy path produces identical params/command', () {
        final plain = PingWindows('8.8.8.8', 1, 1, 2, 255, IpVersion.ipv4);
        final coded = PingWindows(
          '8.8.8.8',
          1,
          1,
          2,
          255,
          IpVersion.ipv4,
          forceCodepage: true,
        );
        // forceCodepage changes the LAUNCH (chcp + runInShell), not the ping
        // command string the host is interpolated into.
        expect(coded.params, plain.params);
        expect(coded.command, plain.command);
      });
    });
  });
}
