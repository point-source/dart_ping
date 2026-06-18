import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/address_family.dart';
import 'package:test/test.dart';

void main() {
  group('ipLiteralFamily', () {
    test('classifies IPv4 literals as ipv4', () {
      expect(ipLiteralFamily('127.0.0.1'), IpVersion.ipv4);
      expect(ipLiteralFamily('0.0.0.0'), IpVersion.ipv4);
    });

    test('classifies IPv6 literals as ipv6', () {
      expect(ipLiteralFamily('::1'), IpVersion.ipv6);
      expect(ipLiteralFamily('fe80::1'), IpVersion.ipv6);
      expect(ipLiteralFamily('2001:db8::1'), IpVersion.ipv6);
    });

    test('returns null for hostnames (no DNS resolution)', () {
      expect(ipLiteralFamily('example.com'), isNull);
      expect(ipLiteralFamily('localhost'), isNull);
    });

    test('returns null for non-IP / invalid input', () {
      expect(ipLiteralFamily('not a host'), isNull);
      expect(ipLiteralFamily(''), isNull);
    });
  });
}
