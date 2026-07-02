import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:test/test.dart';

/// §spec:android-ci-gate — parser half; guards §spec:android-output-parity.
///
/// Feeds captured / source-verified stock-toybox `ping` output through the
/// Android parse path ([PingLinux.androidParser]) and asserts each line maps to
/// the expected [PingResponse] / [PingError] / [PingSummary] event, and that a
/// whole session yields accurate transmitted / received / loss counts. This is
/// the SECOND failure mode the gate pins: output that no longer maps to the
/// right events (the first is flag rejection, covered by
/// `android_flag_acceptance_test.dart`). It is pure text-in / event-out — no
/// toybox binary and no live network — so it runs in the normal
/// `dart test -x live` gate on every host.
///
/// The samples live under `test/fixtures/android/` and are the phrasings stock
/// toybox prints, verified against toybox `toys/net/ping.c` and `lib/net.c`
/// (reply/statistics/banner are literal printf formats; the recvmsg-errno and
/// gai_strerror error lines are the toybox wrappers that emit them).
void main() {
  final parser = PingLinux.androidParser;

  // Fixtures are read relative to the package root, which is the working
  // directory `dart test` runs from.
  String fixture(String name) =>
      File('test/fixtures/android/$name').readAsStringSync();

  List<PingEvent> parseSession(String name) => [
    for (final line in const LineSplitter().convert(fixture(name)))
      ?parser.parse(line),
  ];

  group('§spec:android-output-parity — full session parses end-to-end', () {
    test('lossy 5-probe session: 3 responses + summary with 40% loss', () {
      final events = parseSession('session.txt');
      final responses = events.whereType<PingResponse>().toList();
      final summaries = events.whereType<PingSummary>().toList();

      // One PingResponse per reply line; the count equals `received`.
      expect(responses.length, 3);
      expect(responses.map((r) => r.seq), [1, 2, 5]);
      expect(responses.first.ip, '142.250.80.46');
      expect(responses.first.ttl, 115);
      expect(responses.first.time, const Duration(milliseconds: 10));

      // Exactly one terminal summary, with counts taken from toybox's own
      // statistics line — authoritative even though two probes were lost with
      // no per-probe line (toybox has no `-O` equivalent, so a lost probe
      // surfaces only as a lower `received`, never a mid-run requestTimedOut).
      expect(summaries, hasLength(1));
      final summary = summaries.single;
      expect(summary.transmitted, 5);
      expect(summary.received, 3);
      expect(responses.length, summary.received);
      // toybox's statistics line has no trailing wall-clock total, so `time` is
      // null on Android (the field is nullable; every other field is set).
      expect(summary.time, isNull);
    });

    test('clean 4-probe session: 4 responses + summary with 0% loss', () {
      final events = parseSession('clean_session.txt');
      final responses = events.whereType<PingResponse>().toList();
      final summary = events.whereType<PingSummary>().single;

      expect(responses.length, 4);
      expect(summary.transmitted, 4);
      expect(summary.received, 4);
      expect(responses.length, summary.received);
    });
  });

  group('§spec:android-output-parity — error lines map to the right kind', () {
    // Each fixture line is `<expectedErrorType> | <exact toybox output line>`.
    final cases = const LineSplitter()
        .convert(fixture('errors.txt'))
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
        expect((event as PingError).error.name, c.name);
      });
    }
  });

  test('desktop-Linux (iputils) parser is untouched by the Android variance', () {
    // Regression guard carried over from parse_test.dart: the Android statistics
    // phrasing (no trailing `time <n>ms`) must NOT be accepted by the iputils
    // defaultParser, whose summary still requires that trailing total.
    final linux = PingLinux.defaultParser;
    expect(
      linux.parse('5 packets transmitted, 3 received, 40% packet loss'),
      isNull,
    );
    expect(
      linux.parse(
        '4 packets transmitted, 3 received, 25% packet loss, time 3026ms',
      ),
      isA<PingSummary>(),
    );
  });
}
