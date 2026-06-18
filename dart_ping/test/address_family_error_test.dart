import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';
import 'package:test/test.dart';

void main() {
  // §spec:address-family-error-honesty — routing / address-family failures must
  // map to the additive ErrorType.noRoute, while genuine name-resolution
  // failures stay ErrorType.unknownHost and ambiguous errors stay
  // ErrorType.unknown. These cases are deterministic and network-free.
  group('No-route / address-family errors map to ErrorType.noRoute: ', () {
    test('Linux destination host unreachable', () {
      final res = PingLinux.defaultParser.parse(
        'From 10.0.0.1 icmp_seq=1 Destination Host Unreachable',
      );
      expect(res!.error!.error, ErrorType.noRoute);
    });

    test('Linux network is unreachable', () {
      final res =
          PingLinux.defaultParser.parse('connect: Network is unreachable');
      expect(res!.error!.error, ErrorType.noRoute);
    });

    test('macOS no route to host', () {
      final res =
          PingMac.defaultParser.parse('ping: sendto: No route to host');
      expect(res!.error!.error, ErrorType.noRoute);
    });

    test('Windows destination host unreachable', () {
      final res = PingWindows.defaultParser.parse(
        'Reply from 10.0.0.1: Destination host unreachable.',
      );
      expect(res!.error!.error, ErrorType.noRoute);
    });
  });

  group('Genuine name-resolution failures stay ErrorType.unknownHost: ', () {
    test('Linux unknown host', () {
      final res =
          PingLinux.defaultParser.parse('ping: unknown host example.invalid');
      expect(res!.error!.error, ErrorType.unknownHost);
    });

    test('macOS unknown host', () {
      final res =
          PingMac.defaultParser.parse('ping: cannot resolve foo: Unknown host');
      expect(res!.error!.error, ErrorType.unknownHost);
    });

    test('Windows could not find host', () {
      final res = PingWindows.defaultParser
          .parse('Ping request could not find host foo.');
      expect(res!.error!.error, ErrorType.unknownHost);
    });
  });

  group('Ambiguous errors stay ErrorType.unknown: ', () {
    test('Windows general failure', () {
      final res = PingWindows.defaultParser.parse('General failure.');
      expect(res!.error!.error, ErrorType.unknown);
    });
  });
}
