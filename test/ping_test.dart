@Tags(['live'])
library;

import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  final seq = Platform.operatingSystem == 'macos' ? 0 : 1;

  group('Pinging host: ', () {
    test('google.com', () async {
      Ping ping = Ping('google.com', count: 1);
      PingEvent data = await ping.stream.first;
      expect(data, isA<PingResponse>());
      expect((data as PingResponse).seq, seq);
    });

    test('1.1.1.1', () async {
      Ping ping = Ping('1.1.1.1', count: 1);
      PingEvent data = await ping.stream.first;
      expect(data, isA<PingResponse>());
      expect((data as PingResponse).ip, '1.1.1.1');
      expect(data.seq, seq);
    });
  });

  group('Error handling: ', () {
    test('Unknown Host', () async {
      Ping ping = Ping('shouldneverresolve', count: 1, timeout: 1);
      PingEvent data = await ping.stream.first;
      expect(data, isA<PingError>());
      expect((data as PingError).error, ErrorType.unknownHost);
    });

    test('TTL Exceeded', () async {
      Ping ping = Ping('201.202.203.204', count: 2, ttl: 1);
      PingEvent data = await ping.stream.last;
      expect(data, isA<PingSummary>());
      expect(
        (data as PingSummary).errors.toString(),
        contains('requestTimedOut'),
      );
    });
  });
}
