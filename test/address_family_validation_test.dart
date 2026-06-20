import 'package:dart_ping/dart_ping.dart';
import 'package:test/test.dart';

void main() {
  group('Address-family / literal mismatch validation: ', () {
    group('mismatch throws ArgumentError synchronously', () {
      test('IPv6 literal (::1) + ipv4', () {
        expect(
          () => Ping('::1', ipVersion: IpVersion.ipv4),
          throwsArgumentError,
        );
      });

      test('IPv6 literal (2001:db8::1) + ipv4', () {
        expect(
          () => Ping('2001:db8::1', ipVersion: IpVersion.ipv4),
          throwsArgumentError,
        );
      });

      test('IPv4 literal (1.2.3.4) + ipv6', () {
        expect(
          () => Ping('1.2.3.4', ipVersion: IpVersion.ipv6),
          throwsArgumentError,
        );
      });

      test('IPv6 literal (::1) + default selection (ipv4)', () {
        expect(() => Ping('::1'), throwsArgumentError);
      });
    });

    group('matching literal does not throw', () {
      test('IPv4 literal (127.0.0.1) + ipv4', () {
        expect(
          () => Ping('127.0.0.1', ipVersion: IpVersion.ipv4),
          returnsNormally,
        );
      });

      test('IPv6 literal (::1) + ipv6', () {
        expect(() => Ping('::1', ipVersion: IpVersion.ipv6), returnsNormally);
      });
    });

    group('hostname is never classified (no DNS resolution)', () {
      test('example.com + ipv4', () {
        expect(
          () => Ping('example.com', ipVersion: IpVersion.ipv4),
          returnsNormally,
        );
      });

      test('example.com + ipv6', () {
        expect(
          () => Ping('example.com', ipVersion: IpVersion.ipv6),
          returnsNormally,
        );
      });
    });
  });
}
