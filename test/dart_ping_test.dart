import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Pinging google..', () {
    Ping ping;

    setUp(() {
      ping = Ping('google.com', count: 3, timeout: 1, interval: 1, ipv6: false);
    });

    test('Instance test', () async {
      expect(await ping.stream.first, isA<PingData>());
    });
  });
}
