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
