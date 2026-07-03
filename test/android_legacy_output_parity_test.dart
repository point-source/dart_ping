import 'dart:convert';

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
/// in the normal `dart test -x live` gate on every host. The sample lines follow
/// the grammar SPEC pins; real captured `external/ping` / `ping6` fixtures are
/// pinned by §spec:android-legacy-ci-gate (Batch 2).
void main() {
  final parser = PingLinux.androidParser;

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
      final e = parser.parse(
        'From 2001:db8::1 icmp_seq=1 Time to live exceeded',
      );
      expect(e, isA<PingError>());
      final err = e! as PingError;
      expect(err.error, ErrorType.timeToLiveExceeded);
      expect(err.seq, 1);
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
