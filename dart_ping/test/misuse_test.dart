import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping_interface.dart';
import 'package:test/test.dart';

void main() {
  group('Misuse: ', () {
    test('Termination before starting', () async {
      var ping = Ping('1.1.1.1', count: 5);
      expect(await ping.stop(), isFalse);
    });
  });

  group('iOS interface rejection: ', () {
    // Same rejection regardless of the selection's form (name or address), so
    // both throwing cases share one matcher.
    final rejected = throwsA(
      isA<UnimplementedError>().having(
        (e) => e.toString(),
        'message',
        allOf(contains('iOS'), contains('not supported')),
      ),
    );

    test('rejects a bare interface name', () {
      expect(() => throwIfInterfaceUnsupportedOnIos('en0'), rejected);
    });

    test('rejects a source address', () {
      expect(() => throwIfInterfaceUnsupportedOnIos('192.168.1.5'), rejected);
    });

    test('null interface is a no-op', () {
      expect(() => throwIfInterfaceUnsupportedOnIos(null), returnsNormally);
    });
  });
}
