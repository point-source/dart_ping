@Tags(['live'])
library;

import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Early termination: ', () {
    test('google.com', () async {
      Ping ping = Ping('google.com', count: 5);
      List<PingEvent> data = <PingEvent>[];
      ping.stream.listen(data.add);
      await Future.delayed(Duration(milliseconds: 1300));
      await ping.stop();
      expect(data.first, isA<PingEvent>());
      expect(data.last, isA<PingSummary>());
    });

    test('1.1.1.1', () async {
      Ping ping = Ping('1.1.1.1', count: 5);
      List<PingEvent> data = <PingEvent>[];
      ping.stream.listen(data.add);
      await Future.delayed(Duration(milliseconds: 1300));
      await ping.stop();
      expect(data.first, isA<PingEvent>());
      expect(data.last, isA<PingSummary>());
    });
  });

  group('Stop after error: ', () {
    test('stop() after unknownHost closes stream', () async {
      Ping ping = Ping('this.host.does.not.exist.invalid', count: 3);
      List<PingEvent> data = <PingEvent>[];
      ping.stream.listen(data.add);
      // Allow the process to fail with unknownHost
      await Future.delayed(Duration(milliseconds: 3000));
      // stop() must return even when the process already exited
      await ping.stop().timeout(Duration(seconds: 5));
      expect(data.last, isA<PingSummary>());
    });
  });
}
