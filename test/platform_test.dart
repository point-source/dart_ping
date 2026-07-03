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
    final ping = PingLinux('host', 3, 1, 2, 64, .ipv4);

    test(
      'params force IPv4 with -4 and include the standard flags + count',
      () {
        expect(ping.params, [
          '-4',
          '-O',
          '-n',
          '-W', '2',
          '-i', '1',
          '-t', '64',
          '-c', '3',
        ]);
      },
    );

    test('params force IPv6 with -6', () {
      final v6 = PingLinux('host', 3, 1, 2, 64, .ipv6);
      expect(v6.params.first, '-6');
    });

    test('executable is the unified ping for both families (not ping6)', () {
      expect(ping.executable, 'ping');
      expect(PingLinux('host', 3, 1, 2, 64, .ipv6).executable, 'ping');
    });

    test('params omit -c when count is null', () {
      final unbounded = PingLinux('host', null, 1, 2, 64, .ipv4);
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

    test('interface name appends -I <name> as separate argv tokens', () {
      final named = PingLinux('host', 3, 1, 2, 64, .ipv4, interface: 'eth0');
      expect(named.params, containsAllInOrder(['-I', 'eth0']));
      // Regression guard: the flag and value must NOT be glued into one token,
      // which would reach ping (launched without a shell) as a single argument
      // with a leading space in the value and fail to bind.
      expect(named.params, isNot(contains('-I eth0')));
      expect(named.command, contains('-I eth0'));
    });

    test('interface address appends -I <address> as separate argv tokens', () {
      final addr = PingLinux(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: '192.168.1.5',
      );
      expect(addr.params, containsAllInOrder(['-I', '192.168.1.5']));
      expect(addr.params, isNot(contains('-I 192.168.1.5')));
      expect(addr.command, contains('-I 192.168.1.5'));
    });

    test('empty interface is a no-op (treated as no selection)', () {
      final empty = PingLinux('host', 3, 1, 2, 64, .ipv4, interface: '');
      expect(empty.params, [
        '-4', '-O', '-n', '-W', '2', '-i', '1', '-t', '64', '-c', '3',
      ]);
      expect(empty.params, isNot(anyElement(startsWith('-I'))));
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: the pre-feature params/command must be
      // identical whether `interface` is unset or explicitly null.
      const expected = [
        '-4', '-O', '-n', '-W', '2', '-i', '1', '-t', '64', '-c', '3',
      ];
      final nullIface = PingLinux('host', 3, 1, 2, 64, .ipv4, interface: null);
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(anyElement(startsWith('-I'))));
    });
  });

  // §spec:android-toybox-flags — Android runs the same subprocess path but must
  // send only flags stock toybox `ping` accepts. Both the `isAndroid` and the
  // `isLegacy` seams are injected explicitly so these run on any host (the suite
  // never runs on Android) WITHOUT triggering the runtime dialect probe — a real
  // subprocess whose result would depend on the CI host's own `ping`.
  group('PingLinux (Android / toybox)', () {
    test('params drop the iputils-only -O and -n', () {
      final android = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
      );
      expect(android.params, isNot(contains('-O')));
      expect(android.params, isNot(contains('-n')));
    });

    test('params still force the family and carry the toybox-accepted flags', () {
      final android = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
      );
      // Exactly the iputils list minus -O/-n: family + wait/interval/ttl/count,
      // each valued flag SPLIT into two argv tokens so toybox's fractional `-i`
      // parser accepts it (a glued `'-i 1'` is rejected as `Not a number ' 1'` —
      // proven against a real toybox by §spec:android-ci-gate).
      expect(android.params, [
        '-4', '-W', '2', '-i', '1', '-t', '64', '-c', '3',
      ]);
    });

    test('params force IPv6 with -6 and still omit -O/-n', () {
      final v6 = PingLinux(
        'host', 3, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: false,
      );
      expect(v6.params, ['-6', '-W', '2', '-i', '1', '-t', '64', '-c', '3']);
    });

    test('IPv6 stays on the single multicall ping (not ping6) on toybox', () {
      // Toybox is one binary that family-pins via `-6`; the executable must stay
      // `ping`, never the legacy split `ping6` (§spec:android-legacy-dialect —
      // must-not-regress-toybox).
      final v6 = PingLinux(
        'host', 3, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: false,
      );
      expect(v6.executable, 'ping');
    });

    test('params omit -c when count is null', () {
      final unbounded = PingLinux(
        'host', null, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
      );
      expect(unbounded.params, ['-4', '-W', '2', '-i', '1', '-t', '64']);
    });

    test('interface binding still appends -I as separate argv tokens', () {
      final named = PingLinux(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: 'eth0',
        isAndroid: true,
        isLegacy: false,
      );
      expect(named.params, [
        '-4', '-W', '2', '-i', '1', '-t', '64', '-c', '3', '-I', 'eth0',
      ]);
    });

    test('desktop Linux params are byte-for-byte unchanged (regression guard)', () {
      // The must-have "desktop Linux is unchanged" guard: the non-Android list
      // still includes -O and -n in the original order. Splitting the valued
      // flags into separate argv tokens is byte-identical for iputils — the
      // `command` string (params joined on spaces) is unchanged.
      final desktop = PingLinux('host', 3, 1, 2, 64, .ipv4, isAndroid: false);
      expect(desktop.params, [
        '-4', '-O', '-n', '-W', '2', '-i', '1', '-t', '64', '-c', '3',
      ]);
      expect(desktop.command, 'ping -4 -O -n -W 2 -i 1 -t 64 -c 3 host');
    });

    test('exit-code interpretation is unchanged from desktop Linux', () {
      // The fix removes the CAUSE of the reported exit 2 (a rejected flag); it
      // does not remap exit codes. A genuinely unmapped non-zero Android exit
      // still surfaces a catchable error via throwExit
      // (§spec:stream-lifecycle-robustness regression guard).
      final android = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: false,
      );
      expect(android.interpretExitCode(1)?.error, ErrorType.noReply);
      expect(android.interpretExitCode(2), isNull);
      expect(android.throwExit(2), isA<Exception>());
    });
  });

  // §spec:android-legacy-dialect — a legacy AOSP `external/ping` image ships a
  // SPLIT `ping` (IPv4-only, which REJECTS `-4`/`-6`) plus a separate `ping6`.
  // The `isLegacy` seam is injected so these run on any host without the runtime
  // dialect probe. The command must be one the legacy binary actually accepts:
  // flagless `ping` for IPv4, the `ping6` executable for IPv6.
  group('PingLinux (Android / legacy AOSP external/ping)', () {
    test('IPv4 params carry NO family flag (legacy ping rejects -4)', () {
      // The default `Ping('google.com')` on a legacy image: the `-4` iputils
      // would send is dropped, so the binary no longer aborts at argument
      // parsing with exit 2. Omitting it still pins the family to IPv4 — the
      // legacy `ping` is physically IPv4-only.
      final legacy = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: true,
      );
      expect(legacy.params, isNot(contains('-4')));
      expect(legacy.params, isNot(contains('-6')));
      expect(legacy.params, ['-W', '2', '-i', '1', '-t', '64', '-c', '3']);
    });

    test('IPv4 launches the unified ping executable', () {
      final legacy = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: true,
      );
      expect(legacy.executable, 'ping');
      expect(legacy.command, 'ping -W 2 -i 1 -t 64 -c 3 host');
    });

    test('IPv6 selects the ping6 executable with no family flag', () {
      // IPv6 lives in a separate binary on legacy images, so the family choice
      // becomes an executable choice (`ping` -> `ping6`) rather than an argument.
      final legacy = PingLinux(
        'host', 3, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: true,
      );
      expect(legacy.executable, 'ping6');
      expect(legacy.params, isNot(contains('-6')));
      expect(legacy.params, ['-W', '2', '-i', '1', '-t', '64', '-c', '3']);
      // `command` renders the real executable (base_ping derives its leading
      // token from `executable`).
      expect(legacy.command, 'ping6 -W 2 -i 1 -t 64 -c 3 host');
    });

    test('interface binding still appends -I as separate argv tokens', () {
      final named = PingLinux(
        'host', 3, 1, 2, 64, .ipv4,
        interface: 'wlan0', isAndroid: true, isLegacy: true,
      );
      expect(named.params, [
        '-W', '2', '-i', '1', '-t', '64', '-c', '3', '-I', 'wlan0',
      ]);
    });

    test('params omit -c when count is null', () {
      final unbounded = PingLinux(
        'host', null, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: true,
      );
      expect(unbounded.params, ['-W', '2', '-i', '1', '-t', '64']);
    });

    test('exit-code interpretation matches every other dialect', () {
      // A genuinely unmapped non-zero exit on a legacy image still surfaces a
      // catchable error (§spec:stream-lifecycle-robustness).
      final legacy = PingLinux(
        'host', 3, 1, 2, 64, .ipv4, isAndroid: true, isLegacy: true,
      );
      expect(legacy.interpretExitCode(1)?.error, ErrorType.noReply);
      expect(legacy.interpretExitCode(2), isNull);
      expect(legacy.throwExit(2), isA<Exception>());
    });
  });

  // §spec:android-legacy-dialect — the classification itself: given a "toybox"
  // seam the flagged single-`ping` command is produced; given a "legacy" seam
  // the flagless / `ping6` command is produced. This is the runtime selection
  // exercised deterministically without an emulator or the live probe.
  group('PingLinux dialect classification drives command selection', () {
    for (final v in IpVersion.values) {
      test('toybox seam -> flagged ${v.label} command on ping', () {
        final toybox = PingLinux(
          'host', 3, 1, 2, 64, v, isAndroid: true, isLegacy: false,
        );
        expect(toybox.params.first, v.flag);
        expect(toybox.executable, 'ping');
      });

      test('legacy seam -> flagless ${v.label} command, ping6 for IPv6', () {
        final legacy = PingLinux(
          'host', 3, 1, 2, 64, v, isAndroid: true, isLegacy: true,
        );
        expect(legacy.params, isNot(anyElement(startsWith('-4'))));
        expect(legacy.params, isNot(anyElement(startsWith('-6'))));
        expect(legacy.executable, v == .ipv6 ? 'ping6' : 'ping');
      });
    }

    test('resolved dialect drives a self-consistent, stable command', () {
      // The command is a pure function of the resolved dialect, so two probes to
      // the same host on the same resolved dialect must produce the identical
      // executable + params — a per-probe re-detection that disagreed would
      // break this. Compare TWO separate instances (not a getter to itself) so
      // the assertion actually has content.
      final a = PingLinux(
        'host', 3, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: true,
      );
      final b = PingLinux(
        'host', 3, 1, 2, 64, .ipv6, isAndroid: true, isLegacy: true,
      );
      expect(a.executable, 'ping6');
      expect(a.executable, b.executable);
      expect(a.params, b.params);
      // A legacy IPv6 command never carries a family flag on any probe.
      expect(a.params, isNot(anyElement(startsWith('-6'))));
    });
  });

  // The runtime probe classifier — the branch that turns a `ping -4` probe into
  // the legacy/toybox verdict — exercised directly against real captured output,
  // so the discriminator is covered without spawning `ping` or an emulator. The
  // real-binary side (that a legacy `external/ping` actually emits this
  // signature) is pinned by the §spec:android-legacy-ci-gate control case.
  group('PingLinux.classifyLegacyFromProbeOutput', () {
    test('legacy `ping -4` output (family flag rejected) -> legacy', () {
      // Exactly what the 2008-vintage AOSP `external/ping` prints for `-4`.
      expect(
        PingLinux.classifyLegacyFromProbeOutput("ping: invalid option -- '4'"),
        isTrue,
      );
    });

    test('the alternate "unrecognized option" phrasing -> legacy', () {
      expect(
        PingLinux.classifyLegacyFromProbeOutput('ping: unrecognized option: 4'),
        isTrue,
      );
    });

    test('classification is case-insensitive', () {
      expect(
        PingLinux.classifyLegacyFromProbeOutput('Ping: Invalid Option -- 4'),
        isTrue,
      );
    });

    test('toybox `ping -4` output (flag accepted, missing operand) -> toybox', () {
      // toybox accepts `-4` and instead complains about the absent target, so
      // the option-rejection signature is absent — must NOT classify as legacy.
      expect(
        PingLinux.classifyLegacyFromProbeOutput('ping: Need an argument'),
        isFalse,
      );
    });

    test('a modern-iputils usage error (no rejected flag) -> toybox', () {
      expect(
        PingLinux.classifyLegacyFromProbeOutput(
          'ping: usage error: Destination address required',
        ),
        isFalse,
      );
    });

    test('empty output (probe produced nothing) -> toybox (safe default)', () {
      expect(PingLinux.classifyLegacyFromProbeOutput(''), isFalse);
    });
  });

  group('PingMac', () {
    final ping = PingMac('host', 3, 1, 2, 64, .ipv4);

    test('params scale the timeout to milliseconds and include the count', () {
      expect(ping.params, ['-n', '-W 2000', '-i 1', '-m 64', '-c 3']);
    });

    test('params omit -c when count is null', () {
      final unbounded = PingMac('host', null, 1, 2, 64, .ipv4);
      expect(unbounded.params, isNot(anyElement(startsWith('-c'))));
    });

    test('params throw for IpVersion.ipv6 (unsupported on the macOS path)', () {
      final ipv6 = PingMac('host', 1, 1, 2, 64, .ipv6);
      expect(() => ipv6.params, throwsUnimplementedError);
    });

    test('locale forces the C locale', () {
      expect(ping.locale, {'LC_ALL': 'C'});
    });

    test('interpretExitCode maps 1/2/68 and ignores the rest', () {
      // BSD `ping` reports "no echo reply" with BOTH exit 1 (pure silence) and
      // exit 2 (ICMP errors back, e.g. TTL-exceeded), so both map to noReply
      // (§spec:mac-all-timeout-summary).
      expect(ping.interpretExitCode(1)?.error, ErrorType.noReply);
      expect(ping.interpretExitCode(2)?.error, ErrorType.noReply);
      expect(ping.interpretExitCode(68)?.error, ErrorType.unknownHost);
      expect(ping.interpretExitCode(0), isNull);
      expect(ping.interpretExitCode(3), isNull);
    });

    test('throwExit ignores 1/2/68 but throws for genuinely-unmapped codes', () {
      // Exit 2 is now a recognized no-reply outcome, so it no longer throws.
      expect(ping.throwExit(2), isNull);
      expect(ping.throwExit(68), isNull);
      expect(ping.throwExit(1), isNull);
      expect(ping.throwExit(0), isNull);
      // A genuinely-unmapped code still surfaces a catchable exception
      // (§spec:stream-lifecycle-robustness).
      expect(ping.throwExit(3), isA<Exception>());
    });

    test('interface name appends -b <name> (boundif) as separate tokens', () {
      final named = PingMac('host', 3, 1, 2, 64, .ipv4, interface: 'en0');
      expect(named.params, containsAllInOrder(['-b', 'en0']));
      expect(named.params, isNot(contains('-b en0')));
      expect(named.command, contains('-b en0'));
      expect(named.params, isNot(contains('-S')));
    });

    test('interface address appends -S <address> as separate tokens', () {
      final addr = PingMac(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: '192.168.1.5',
      );
      expect(addr.params, containsAllInOrder(['-S', '192.168.1.5']));
      expect(addr.params, isNot(contains('-S 192.168.1.5')));
      expect(addr.command, contains('-S 192.168.1.5'));
      expect(addr.params, isNot(contains('-b')));
    });

    test(
      'zone-scoped IPv6 source address is classified as an address (-S)',
      () {
        // `InternetAddress.tryParse` rejects the `%zone` suffix, so the zone is
        // stripped for classification; the full value is still passed to ping.
        final zoned = PingMac(
          'host',
          3,
          1,
          2,
          64,
          .ipv4,
          interface: 'fe80::1%en0',
        );
        expect(zoned.params, containsAllInOrder(['-S', 'fe80::1%en0']));
        expect(zoned.params, isNot(contains('-b')));
      },
    );

    test('empty interface is a no-op (treated as no selection)', () {
      final empty = PingMac('host', 3, 1, 2, 64, .ipv4, interface: '');
      expect(empty.params, ['-n', '-W 2000', '-i 1', '-m 64', '-c 3']);
      expect(empty.params, isNot(anyElement(startsWith('-S'))));
      expect(empty.params, isNot(anyElement(startsWith('-b'))));
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: pre-feature params/command unchanged.
      const expected = ['-n', '-W 2000', '-i 1', '-m 64', '-c 3'];
      final nullIface = PingMac('host', 3, 1, 2, 64, .ipv4, interface: null);
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(anyElement(startsWith('-S'))));
      expect(ping.params, isNot(anyElement(startsWith('-b'))));
    });
  });

  group('PingWindows', () {
    final ping = PingWindows('host', 3, 1, 2, 64, .ipv4);

    test('params for a bounded IPv4 run use -n with the count', () {
      expect(ping.params, ['-w', '2000', '-i', '64', '-4', '-n', '3']);
    });

    test('params for an unbounded run use -t', () {
      final unbounded = PingWindows('host', null, 1, 2, 64, .ipv4);
      expect(unbounded.params, ['-w', '2000', '-i', '64', '-4', '-t']);
    });

    test('params for IpVersion.ipv6 force -6 (#71)', () {
      final ipv6 = PingWindows('host', 3, 1, 2, 64, .ipv6);
      expect(ipv6.params, ['-w', '2000', '-i', '64', '-6', '-n', '3']);
    });

    test('locale requests en_US', () {
      expect(ping.locale, {'LANG': 'en_US'});
    });

    test('interpretExitCode always yields an unknown error with the code', () {
      final error = ping.interpretExitCode(5);
      expect(error.error, ErrorType.unknown);
      expect(error.message, contains('5'));
    });

    test('throwExit always returns an Exception carrying the code', () {
      expect(ping.throwExit(5).toString(), contains('5'));
    });

    test('interface address appends split -S <address> args', () {
      final addr = PingWindows(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: '192.168.1.5',
      );
      expect(addr.params, containsAllInOrder(['-S', '192.168.1.5']));
      expect(addr.command, contains('-S 192.168.1.5'));
    });

    test('bare interface name is rejected at construction', () {
      // Windows `ping` binds only by source address (`-S <address>`), never by
      // interface name, so a bare name must fail loudly rather than silently
      // ping the default route. The rejection happens once at construction (not
      // lazily from `params`/`command`), so inspecting `command` never throws.
      expect(
        () => PingWindows('host', 3, 1, 2, 64, .ipv4, interface: 'eth0'),
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('source address'), contains('interface name')),
          ),
        ),
      );
    });

    test('an accepted source-address selection lets command be inspected', () {
      // Regression guard for the fix that moved rejection to construction: the
      // pure inspection getters must never throw for a valid selection.
      final addr = PingWindows(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: '192.168.1.5',
      );
      expect(() => addr.command, returnsNormally);
      expect(() => addr.params, returnsNormally);
    });

    test('zone-scoped IPv6 source address is accepted, not rejected', () {
      // A legitimate source address with an IPv6 zone id must not be mistaken
      // for a bare interface name and rejected.
      expect(
        () =>
            PingWindows('host', 3, 1, 2, 64, .ipv4, interface: 'fe80::1%eth0'),
        returnsNormally,
      );
    });

    test('empty interface is a no-op, not a rejected name', () {
      final empty = PingWindows('host', 3, 1, 2, 64, .ipv4, interface: '');
      expect(empty.params, ['-w', '2000', '-i', '64', '-4', '-n', '3']);
      expect(empty.params, isNot(contains('-S')));
    });

    test('omitting interface (or null) is byte-for-byte unchanged', () {
      // Backward-compat guard: pre-feature params/command unchanged.
      const expected = ['-w', '2000', '-i', '64', '-4', '-n', '3'];
      final nullIface = PingWindows(
        'host',
        3,
        1,
        2,
        64,
        .ipv4,
        interface: null,
      );
      expect(ping.params, expected);
      expect(nullIface.params, expected);
      expect(nullIface.params, ping.params);
      expect(nullIface.command, ping.command);
      expect(ping.params, isNot(contains('-S')));
    });
  });

  group('Ping factory interface threading', () {
    // The factory only builds the class matching the host OS, so assert the
    // selection reaches the spawned command rather than being dropped by the
    // factory. A source-address selection is honored on every desktop host
    // (Linux `-I`, macOS `-S`, Windows `-S`), so this runs on any CI runner.
    test('threads a source address through to the spawned command', () {
      final ping = Ping('host', count: 1, interface: '192.168.1.5');
      expect(ping.command, contains('192.168.1.5'));
    });

    test('omitting interface leaves the command free of binding flags', () {
      final plain = Ping('host', count: 1);
      final selected = Ping('host', count: 1, interface: '192.168.1.5');
      expect(plain.command, isNot(contains('192.168.1.5')));
      expect(selected.command, isNot(equals(plain.command)));
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
      expect(() => PingLinux('::1', 1, 1, 2, 64, .ipv4), throwsArgumentError);
    });

    test('PingMac with an IPv4 literal + ipv6 throws ArgumentError', () {
      expect(() => PingMac('1.2.3.4', 1, 1, 2, 64, .ipv6), throwsArgumentError);
    });

    test('a matching literal constructs normally', () {
      expect(() => PingLinux('127.0.0.1', 1, 1, 2, 64, .ipv4), returnsNormally);
    });
  });
}
