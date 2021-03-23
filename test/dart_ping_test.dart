import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Testing ping against host: ', () {
    test('google.com', () async {
      var ping =
          Ping('google.com', count: 1, timeout: 1, interval: 1, ipv6: false);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.response?.seq, 0);
    });

    test('1.1.1.1', () async {
      var ping =
          Ping('1.1.1.1', count: 1, timeout: 1, interval: 1, ipv6: false);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.response?.ip, '1.1.1.1');
      expect(data.response?.seq, 0);
    });

    test('shouldneverresolve', () async {
      var ping = Ping('shouldneverresolve',
          count: 1, timeout: 1, interval: 1, ipv6: false);
      var data = await ping.stream.first;
      expect(data, isA<PingData>());
      expect(data.error?.error, ErrorType.UnknownHost);
    });
  });
}
