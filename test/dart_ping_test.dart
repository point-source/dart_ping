import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  final seq = Platform.operatingSystem == 'macos' ? 0 : 1;
  group('Pinging host: ', () {
    test('google.com', () async {
      var ping = Ping('google.com', count: 1);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.response?.seq, seq);
    });

    test('1.1.1.1', () async {
      var ping = Ping('1.1.1.1', count: 1);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.response?.ip, '1.1.1.1');
      expect(data.response?.seq, seq);
    });
  });

  group('Error handling: ', () {
    test('Unknown Host', () async {
      var ping = Ping('shouldneverresolve', count: 1, timeout: 1);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.error?.error, ErrorType.UnknownHost);
    });

    test('TTL Exceeded', () async {
      var ping = Ping('201.202.203.204', count: 2, ttl: 1);
      var data = await ping.stream.last;
      expect(data, isA<PingData>());
      expect(data.summary?.errors.toString(), contains('NoReply'));
    });
  });

  group('Early termination: ', () {
    test('google.com', () async {
      var ping = Ping('google.com', count: 5);
      var data = <PingData>[];
      ping.stream.listen(data.add);
      await Future.delayed(Duration(milliseconds: 1300));
      await ping.stop();
      expect(data.first, isA<PingData>());
      expect(data.last.summary, isNotNull);
    });

    test('1.1.1.1', () async {
      var ping = Ping('1.1.1.1', count: 5);
      var data = <PingData>[];
      ping.stream.listen(data.add);
      await Future.delayed(Duration(milliseconds: 1300));
      await ping.stop();
      expect(data.first, isA<PingData>());
      expect(data.last.summary, isNotNull);
    });
  });

  group('Misuse: ', () {
    test('Termination before starting', () async {
      var ping = Ping('1.1.1.1', count: 5);
      expect(ping.stop(), throwsException);
    });
  });
}
