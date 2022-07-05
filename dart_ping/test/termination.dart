import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
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
}
