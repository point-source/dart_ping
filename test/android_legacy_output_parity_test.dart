import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// §spec:android-legacy-output-parity — the ONE superset [PingLinux.androidParser]
/// must parse legacy AOSP `external/ping` / `ping6` output into the same
/// [PingResponse] / [PingError] / [PingSummary] events a desktop-Linux run
/// produces. Legacy output *is* iputils output (2008 vintage), so this exercises
/// the widened patterns: an IPv6 reply line, a statistics line that DOES carry a
/// trailing wall-clock `time`, and the shared unknown-host / no-route /
/// TTL-exceeded phrasings.
///
/// Pure text-in / event-out — no legacy binary and no live network — so it runs
/// in the normal `dart test -x live` gate on every host. The focused cases below
/// pin individual patterns; the §spec:android-legacy-ci-gate half feeds whole
/// captured `external/ping` / `ping6` sessions from `test/fixtures/android/`
/// (the `legacy_*` files, alongside the toybox fixtures) through the same parser
/// and asserts accurate transmitted / received / loss counts.
void main() {
  final parser = PingLinux.androidParser;

  // Fixtures are read relative to the package root, which is the working
  // directory `dart test` runs from — the same convention as
  // android_output_parity_test.dart (toybox fixtures).
  String fixture(String name) =>
      File('test/fixtures/android/$name').readAsStringSync();

  List<PingEvent> parseSession(String name) => [
    for (final line in const LineSplitter().convert(fixture(name)))
      ?parser.parse(line),
  ];

  group('§spec:android-legacy-output-parity — reply lines', () {
    test('IPv4 reply carries ip / seq / ttl / round-trip time', () {
      final e = parser.parse(
        '64 bytes from 142.250.80.46: icmp_seq=1 ttl=115 time=9.30 ms',
      );
      expect(e, isA<PingResponse>());
      final r = e! as PingResponse;
      expect(r.ip, '142.250.80.46');
      expect(r.seq, 1);
      expect(r.ttl, 115);
      expect(r.time, const Duration(microseconds: 9300));
    });

    test('IPv6 reply carries the full IPv6 address and yields a response', () {
      // The legacy `ping6` binary prints an IPv6 address rather than a dotted
      // quad; the superset `ip` group must capture the whole address (not just
      // its last colon-separated group) so an IPv6 run produces per-probe
      // replies, not merely a summary.
      final e = parser.parse(
        '64 bytes from 2607:f8b0:4005:809::200e: icmp_seq=2 ttl=57 time=11.6 ms',
      );
      expect(e, isA<PingResponse>());
      final r = e! as PingResponse;
      expect(r.ip, '2607:f8b0:4005:809::200e');
      expect(r.seq, 2);
      expect(r.ttl, 57);
      expect(r.time, const Duration(microseconds: 11600));
    });

    test('IPv6 loopback reply (::1) parses', () {
      final e = parser.parse(
        '64 bytes from ::1: icmp_seq=1 ttl=64 time=0.045 ms',
      );
      expect(e, isA<PingResponse>());
      expect((e! as PingResponse).ip, '::1');
    });
  });

  group('§spec:android-legacy-output-parity — statistics line', () {
    test('legacy stats line populates transmitted / received / time', () {
      // The legacy iputils line DOES carry the trailing wall-clock total; the
      // superset summary pattern captures it (unlike toybox, where it is absent
      // and `time` is null).
      final e = parser.parse(
        '4 packets transmitted, 3 received, 25% packet loss, time 3026ms',
      );
      expect(e, isA<PingSummary>());
      final s = e! as PingSummary;
      expect(s.transmitted, 4);
      expect(s.received, 3);
      expect(s.time, const Duration(milliseconds: 3026));
    });

    test('the toybox stats line (no trailing time) still parses -> time null', () {
      // Same superset parser, both dialects: the trailing `time` is optional.
      final e = parser.parse('5 packets transmitted, 3 received, 40% packet loss');
      expect(e, isA<PingSummary>());
      final s = e! as PingSummary;
      expect(s.transmitted, 5);
      expect(s.received, 3);
      expect(s.time, isNull);
    });
  });

  group('§spec:android-legacy-output-parity — error lines map to the right kind', () {
    final cases = <(String, ErrorType)>[
      ('ping: unknown host', ErrorType.unknownHost),
      ('ping6: unknown host www.example.invalid', ErrorType.unknownHost),
      ('connect: Network is unreachable', ErrorType.noRoute),
      ('From 192.168.1.1: No route to host', ErrorType.noRoute),
    ];
    for (final (line, type) in cases) {
      test('$type: "$line"', () {
        final e = parser.parse(line);
        expect(e, isA<PingError>());
        expect((e! as PingError).error, type);
      });
    }

    test('IPv6 TTL-exceeded -> timeToLiveExceeded carrying hop ip + seq', () {
      // ping6 prints the ICMPv6 wording `Time exceeded: Hop limit` (NOT the IPv4
      // `Time to live exceeded`), verified against iputils `ping6.c` pr_icmph.
      final e = parser.parse(
        'From 2001:db8::1 icmp_seq=1 Time exceeded: Hop limit',
      );
      expect(e, isA<PingError>());
      final err = e! as PingError;
      expect(err.error, ErrorType.timeToLiveExceeded);
      expect(err.seq, 1);
      expect(err.ip, '2001:db8::1');
    });

    test('IPv6 TTL-exceeded with a colon-prefixed hop (inline recvmsg form)', () {
      // The kernel can deliver the ICMPv6 error inline (`From <hop>: icmp_seq=`,
      // ping6.c line ~1403) rather than via the error queue (`From <hop>
      // icmp_seq=`, line ~1062); the parser tolerates the optional `:` without
      // capturing it into `ip`.
      final e = parser.parse(
        'From 2001:db8::1: icmp_seq=3 Time exceeded: Hop limit',
      );
      expect(e, isA<PingError>());
      final err = e! as PingError;
      expect(err.error, ErrorType.timeToLiveExceeded);
      expect(err.seq, 3);
      expect(err.ip, '2001:db8::1');
    });
  });

  group('§spec:android-legacy-output-parity — full session parses end-to-end', () {
    // A lossy legacy IPv6 session: 4 sent, 3 replies, one lost. The lost probe
    // surfaces ONLY as a lower `received` + 25% loss (no `-O` on Android, so no
    // mid-run requestTimedOut), exactly as on toybox.
    const session = '''
PING google.com(2607:f8b0:4005:809::200e) 56 data bytes
64 bytes from 2607:f8b0:4005:809::200e: icmp_seq=1 ttl=57 time=11.6 ms
64 bytes from 2607:f8b0:4005:809::200e: icmp_seq=2 ttl=57 time=12.1 ms
64 bytes from 2607:f8b0:4005:809::200e: icmp_seq=4 ttl=57 time=10.9 ms

--- google.com ping statistics ---
4 packets transmitted, 3 received, 25% packet loss, time 3005ms
rtt min/avg/max/mdev = 10.900/11.533/12.100/0.492 ms''';

    final events = [
      for (final line in const LineSplitter().convert(session)) ?parser.parse(line),
    ];

    test('3 IPv6 responses + one summary with accurate counts and loss', () {
      final responses = events.whereType<PingResponse>().toList();
      final summary = events.whereType<PingSummary>().single;

      expect(responses.length, 3);
      expect(responses.map((r) => r.seq), [1, 2, 4]);
      expect(responses.every((r) => r.ip == '2607:f8b0:4005:809::200e'), isTrue);

      expect(summary.transmitted, 4);
      expect(summary.received, 3);
      expect(responses.length, summary.received);
      // Loss is reported accurately even though the lost probe had no per-probe
      // line: received (3) < transmitted (4).
      expect(summary.received < summary.transmitted, isTrue);
      // The legacy line carries the wall-clock total (unlike toybox).
      expect(summary.time, const Duration(milliseconds: 3005));
    });

    test('the rtt min/avg/max/mdev line is inert (stats come from base_ping)', () {
      // §spec:stats-cross-platform: summary `stats` is computed from per-probe
      // RTTs by base_ping, so the legacy rtt line need not (and does not) yield
      // its own event.
      expect(
        parser.parse('rtt min/avg/max/mdev = 10.900/11.533/12.100/0.492 ms'),
        isNull,
      );
    });
  });

  group('§spec:android-legacy-ci-gate — captured legacy sessions parse', () {
    // Full source-verified `external/ping` (IPv4) and `ping6` (IPv6) sessions,
    // fed line-by-line through the SAME parser dart_ping uses on a legacy
    // Android image, asserting accurate transmitted / received / loss.
    test('legacy IPv4 session: 3 responses + summary with 40% loss', () {
      final events = parseSession('legacy_session_ipv4.txt');
      final responses = events.whereType<PingResponse>().toList();
      final summary = events.whereType<PingSummary>().single;

      // One PingResponse per reply line; the count equals `received`. The two
      // lost probes (seq 3, 4) surface only as a lower `received` + non-zero
      // loss — no `-O` on Android, so no mid-run requestTimedOut.
      expect(responses.length, 3);
      expect(responses.map((r) => r.seq), [1, 2, 5]);
      expect(responses.first.ip, '142.250.80.46');
      expect(responses.first.ttl, 115);
      expect(responses.first.time, const Duration(microseconds: 9300));

      expect(summary.transmitted, 5);
      expect(summary.received, 3);
      expect(responses.length, summary.received);
      // The legacy iputils statistics line carries the trailing wall-clock
      // total (unlike toybox, where it is absent and `time` is null).
      expect(summary.time, const Duration(milliseconds: 4003));
    });

    test('legacy IPv6 (ping6) session: 3 responses + summary with 25% loss', () {
      final events = parseSession('legacy_session_ipv6.txt');
      final responses = events.whereType<PingResponse>().toList();
      final summary = events.whereType<PingSummary>().single;

      expect(responses.length, 3);
      expect(responses.map((r) => r.seq), [1, 2, 4]);
      // The superset `ip` group captures the WHOLE IPv6 address, so an IPv6 run
      // yields per-probe replies, not merely a summary.
      expect(
        responses.every((r) => r.ip == '2607:f8b0:4005:809::200e'),
        isTrue,
      );
      expect(responses.first.ttl, 57);
      expect(responses.first.time, const Duration(microseconds: 11600));

      expect(summary.transmitted, 4);
      expect(summary.received, 3);
      expect(responses.length, summary.received);
      expect(summary.time, const Duration(milliseconds: 3005));
    });
  });

  group('§spec:android-legacy-ci-gate — captured legacy error lines', () {
    // Each fixture line is `<expectedErrorType> | <exact legacy output line>`,
    // covering unknown-host (v4 + v6), unreachable / no-route, and TTL-exceeded
    // (v4 + v6) — the same loader shape as the toybox errors.txt.
    final cases = const LineSplitter()
        .convert(fixture('legacy_errors.txt'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) {
          final i = l.indexOf('|');
          return (
            name: l.substring(0, i).trim(),
            line: l.substring(i + 1).trim(),
          );
        });

    for (final c in cases) {
      test('${c.name}: "${c.line}"', () {
        final event = parser.parse(c.line);
        expect(event, isA<PingError>());
        expect((event! as PingError).error.name, c.name);
      });
    }

    test('legacy TTL-exceeded lines carry the hop ip + probe seq', () {
      // Beyond the bare kind, the v4 and v6 hop lines recover the hop `ip` and
      // the original probe `seq` (traceroute-style diagnostics parity).
      final v4 = parser.parse('From 10.0.0.1 icmp_seq=1 Time to live exceeded')!
          as PingError;
      expect(v4.ip, '10.0.0.1');
      expect(v4.seq, 1);

      final v6 =
          parser.parse('From 2001:db8::1 icmp_seq=2 Time exceeded: Hop limit')!
              as PingError;
      expect(v6.ip, '2001:db8::1');
      expect(v6.seq, 2);
    });
  });

  test('reply parsing is linear-time on crafted input (ReDoS guard)', () {
    // The Android reply `ip` group captures IPv6, whose hex/colon alphabet
    // overlaps the reverse-DNS names `ping` prints (Android resolves names —
    // `-n` is absent). A naive IPv6 sub-pattern (overlapping `:`-stars + a lazy
    // prefix) backtracks cubically on a long attacker-influenced line that never
    // reaches the `: icmp_seq=…` tail, blocking the isolate. This pins that a
    // large crafted line is rejected effectively instantly.
    final sw = Stopwatch()..start();
    for (final payload in [
      'bytes from ${':' * 20000}',
      'bytes from ${'a' * 20000}',
      'bytes from ${'aaaa:' * 4000}',
    ]) {
      expect(parser.parse(payload), isNull);
    }
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(1000),
      reason: 'parsing crafted lines must stay near-linear, not backtrack',
    );
  });

  test('TTL-exceeded parsing is linear-time on crafted hop lines (ReDoS guard)', () {
    // The TTL-exceeded `From <hop> … icmp_seq=… Time (to live exceeded|exceeded:
    // Hop limit)` pattern is reached by an attacker-influenced reverse-DNS hop
    // name (Android resolves names — `-n` is absent). The earlier
    // `From (?<ip>.*)(?:.*) icmp_seq=` form — two adjacent unbounded quantifiers
    // over the same alphabet — backtracked quadratically on a long `From …` line
    // that never reaches the tail (a spoofed/long-PTR hop returning ICMP
    // unreachable/TTL), blocking the isolate. This pins that such lines are
    // rejected effectively instantly. (The Android superset TTL pattern now
    // diverges from the desktop-Linux [PingLinux.defaultParser] one, which is
    // exercised separately; both are ReDoS-safe by the same reasoning.)
    final sw = Stopwatch()..start();
    for (final payload in [
      'From ${'a' * 40000}: No route to host', // starts `From `, never reaches the tail
      'From ${'a' * 40000} icmp_seq=1 Destination Host Unreachable', // has icmp_seq, wrong tail
      'From ${'aaaa:' * 8000} icmp_seq=1 Destination Host Unreachable',
    ]) {
      // These are NOT TTL-exceeded lines, so they must not yield that event —
      // the first/last are noRoute, the middle is Destination-Host-Unreachable
      // (noRoute); none should be timeToLiveExceeded.
      final event = parser.parse(payload);
      expect(event, isNot(isA<PingError>().having((e) => e.error, 'error', ErrorType.timeToLiveExceeded)));
    }
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(1000),
      reason: 'TTL-exceeded parsing of crafted hop lines must stay near-linear',
    );
  });

  test('desktop-Linux (iputils) parser stays IPv4-only (regression guard)', () {
    // The superset IPv6 reply capture lives ONLY on the Android parser. The
    // desktop `defaultParser` must NOT gain IPv6 reply parsing — its `ip` group
    // is the IPv4 dotted quad, so an IPv6 reply line yields no response there.
    final linux = PingLinux.defaultParser;
    expect(
      linux.parse(
        '64 bytes from 2607:f8b0:4005:809::200e: icmp_seq=1 ttl=57 time=11.6 ms',
      ),
      isNull,
    );
    // ...while its IPv4 reply parsing is unchanged.
    expect(
      linux.parse('64 bytes from 142.250.80.46: icmp_seq=1 ttl=115 time=9 ms'),
      isA<PingResponse>(),
    );
  });
}
