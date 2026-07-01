import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

import 'package:dart_ping/dart_ping.dart';

void main() {
  group('Parsing (macOS): ', () {
    final parser = PingMac.defaultParser;
    final strings = Responses(
      response: '64 bytes from 8.8.8.8: icmp_seq=0 ttl=37 time=4.204 ms',
      summary: '4 packets transmitted, 3 packets received, 25.0% packet loss',
      timeout: 'Request timeout for icmp_seq 0',
      unknownHost: 'ping: cannot resolve myUnknownHost: Unknown host',
      exceedTtl: '92 bytes from 172.17.0.1: Time to live exceeded',
    );

    test('Response', () async {
      final res = parser.parse(strings.response);
      expect(res, isA<PingResponse>());
      expect((res as PingResponse).seq, 0);
      expect(res.ip, '8.8.8.8');
      expect(res.ttl, 37);
    });

    test('Summary', () async {
      final res = parser.parse(strings.summary);
      expect(res, isA<PingSummary>());
      expect((res as PingSummary).transmitted, 4);
      expect(res.received, 3);
    });

    test('Timeout', () async {
      final res = parser.parse(strings.timeout);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.requestTimedOut);
      expect(res.seq, 0);
    });

    test('Unknown Host', () async {
      final res = parser.parse(strings.unknownHost);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknownHost);
    });

    test('TTL Exceeded', () async {
      final res = parser.parse(strings.exceedTtl);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.timeToLiveExceeded);
      expect(res.ip, '172.17.0.1');
    });

    test('No route to host', () async {
      final res = parser.parse('ping: sendto: No route to host');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });

    test(
      'Host is down maps to unknown (host liveness, not a routing failure)',
      () async {
        final res = parser.parse('ping: sendto: Host is down');
        expect(res, isA<PingError>());
        expect((res as PingError).error, ErrorType.unknown);
      },
    );

    test('Network is unreachable (macOS)', () async {
      final res = parser.parse('ping: sendto: Network is unreachable');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });
  });

  group('Parsing (Linux): ', () {
    final parser = PingLinux.defaultParser;
    final strings = Responses(
      response:
          '64 bytes from myhostname.net (8.8.8.8): icmp_seq=1 ttl=37 time=4.00 ms',
      summary:
          '4 packets transmitted, 3 received, 25% packet loss, time 3026ms',
      timeout: 'no answer yet for icmp_seq=1',
      unknownHost: 'ping: unknownHost: Name or service not known',
      exceedTtl:
          'From 172.17.0.1 (172.17.0.1) icmp_seq=1 Time to live exceeded',
    );

    test('Response', () async {
      final res = parser.parse(strings.response);
      expect(res, isA<PingResponse>());
      expect((res as PingResponse).seq, 1);
      expect(res.ip, '8.8.8.8');
      expect(res.ttl, 37);
    });

    test('Summary', () async {
      final res = parser.parse(strings.summary);
      expect(res, isA<PingSummary>());
      expect((res as PingSummary).transmitted, 4);
      expect(res.received, 3);
    });

    test('Timeout carries the probe seq on a single PingError', () async {
      final res = parser.parse(strings.timeout);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.requestTimedOut);
      expect(res.seq, 1);
    });

    test('Unknown Host', () async {
      final res = parser.parse(strings.unknownHost);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknownHost);
    });

    test('TTL Exceeded carries seq and hop ip on a single PingError', () async {
      final res = parser.parse(strings.exceedTtl);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.timeToLiveExceeded);
      expect(res.seq, 1);
      expect(res.ip, contains('172.17.0.1'));
    });

    test('Network is unreachable (Linux)', () async {
      final res = parser.parse('ping: connect: Network is unreachable');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });

    test('Destination host unreachable (Linux)', () async {
      final res = parser.parse(
        'From 192.168.1.1 icmp_seq=1 Destination Host Unreachable',
      );
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });
  });

  // §spec:android-output-parity — Android ships toybox `ping`, whose reply grammar
  // matches iputils but whose statistics line and name-resolution error are phrased
  // differently. Fixtures below are the EXACT literal strings stock toybox `ping`
  // prints (verified against toybox `toys/net/ping.c`), so an Android run maps the
  // same logical outcomes to the same events as desktop Linux.
  group('Parsing (Android / toybox): ', () {
    final parser = PingLinux.androidParser;

    test('Reply parses to a PingResponse with ip/seq/ttl/time', () {
      // toybox: `%d bytes from %s: icmp_seq=%d ttl=%d time=%u ms` — numeric IP
      // (no reverse DNS), integer milliseconds.
      final res = parser.parse(
        '64 bytes from 142.250.80.46: icmp_seq=1 ttl=115 time=10 ms',
      );
      expect(res, isA<PingResponse>());
      final r = res as PingResponse;
      expect(r.ip, '142.250.80.46');
      expect(r.seq, 1);
      expect(r.ttl, 115);
      expect(r.time, const Duration(milliseconds: 10));
    });

    test('Statistics line drives transmitted/received/loss; time is null', () {
      // toybox: `%lu packets transmitted, %lu received, %ld%% packet loss` — no
      // trailing wall-clock `time <n>ms`, so the summary's `time` is null while
      // every other field is populated. These counts are authoritative: toybox
      // emits no per-lost-probe line, so loss is honest only from THIS line.
      final res = parser.parse('5 packets transmitted, 3 received, 40% packet loss');
      expect(res, isA<PingSummary>());
      final s = res as PingSummary;
      expect(s.transmitted, 5);
      expect(s.received, 3);
      expect(s.time, isNull);
    });

    test('Statistics line reports zero loss for a clean run', () {
      final res =
          parser.parse('4 packets transmitted, 4 received, 0% packet loss');
      expect(res, isA<PingSummary>());
      expect((res as PingSummary).transmitted, 4);
      expect(res.received, 4);
    });

    test('Name-resolution failure `bad address` maps to unknownHost', () {
      // toybox `xgetaddrinfo` prints `<host>: bad address` on Android — the
      // iputils unknownHostStr would miss it (§spec:android-output-parity).
      final res = parser.parse('google.invalid: bad address');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknownHost);
    });

    test('Network unreachable (recvmsg errno) maps to noRoute', () {
      // toybox surfaces kernel ICMP errors via `perror_exit("recvmsg")`, i.e.
      // `recvmsg: <strerror>`; the existing noRouteStrs already catch these.
      final res = parser.parse('recvmsg: Network is unreachable');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });

    test('No route to host (recvmsg errno) maps to noRoute', () {
      final res = parser.parse('recvmsg: No route to host');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
    });

    test('desktop Linux parser is untouched (regression guard)', () {
      // Android variance is confined to androidParser; the iputils defaultParser
      // still requires the trailing `time <n>ms` on its summary line and does not
      // match toybox output.
      final linux = PingLinux.defaultParser;
      expect(
        linux.parse('5 packets transmitted, 3 received, 40% packet loss'),
        isNull,
      );
      expect(
        linux.parse('4 packets transmitted, 3 received, 25% packet loss, time 3026ms'),
        isA<PingSummary>(),
      );
    });
  });

  group('Parsing (Windows): ', () {
    final parser = PingWindows.defaultParser;
    final strings = Responses(
      response: 'Reply from 8.8.8.8: bytes=32 time=6ms TTL=37',
      summary: 'Packets: Sent = 4, Received = 3, Lost = 0 (0% loss),',
      timeout: 'Request timed out.',
      unknownHost:
          'Ping request could not find host unknownHost. Please check the name and try again.',
      exceedTtl: 'Reply from 10.20.60.1: TTL expired in transit.',
    );

    test('Response', () async {
      final res = parser.parse(strings.response);
      expect(res, isA<PingResponse>());
      expect((res as PingResponse).seq, null);
      expect(res.ip, '8.8.8.8');
      expect(res.ttl, 37);
    });

    test('Response (IPv6 — no bytes=/TTL=, #71)', () async {
      // Windows IPv6 replies omit `bytes=` and `TTL=` (see #71):
      //   Reply from ::1: time<1ms
      final res = parser.parse('Reply from ::1: time<1ms');
      expect(res, isA<PingResponse>());
      expect((res as PingResponse).ip, '::1');
      expect(res.time, isNotNull);
      // No hop TTL is reported on the IPv6 reply line.
      expect(res.ttl, null);
    });

    test('Summary', () async {
      final res = parser.parse(strings.summary);
      expect(res, isA<PingSummary>());
      expect((res as PingSummary).transmitted, 4);
      expect(res.received, 3);
    });

    test('Timeout', () async {
      final res = parser.parse(strings.timeout);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.requestTimedOut);
    });

    test('Unknown Host', () async {
      final res = parser.parse(strings.unknownHost);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknownHost);
    });

    test('TTL Exceeded', () async {
      final res = parser.parse(strings.exceedTtl);
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.timeToLiveExceeded);
    });

    test('General Failure', () async {
      final res = parser.parse('General failure.');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknown);
      expect(res.message ?? '', isNotEmpty);
    });

    test('Transmit Failed', () async {
      final res = parser.parse('PING: transmit failed. General failure.');
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.unknown);
      expect(res.message ?? '', isNotEmpty);
    });

    test('Host Unreachable', () async {
      final res = parser.parse(
        'Reply from 10.20.61.15: Destination host unreachable.',
      );
      expect(res, isA<PingError>());
      expect((res as PingError).error, ErrorType.noRoute);
      expect(res.message ?? '', isNotEmpty);
    });
  });
}

class Responses {
  final String response;
  final String summary;
  final String timeout;
  final String unknownHost;
  final String exceedTtl;

  const Responses({
    required this.response,
    required this.summary,
    required this.timeout,
    required this.unknownHost,
    required this.exceedTtl,
  });
}
