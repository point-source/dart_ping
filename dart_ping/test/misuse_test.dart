import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Misuse: ', () {
    test('Termination before starting', () async {
      var ping = Ping('1.1.1.1', count: 5);
      expect(await ping.stop(), isFalse);
    });
  });
}
