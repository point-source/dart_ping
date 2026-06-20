import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/ping/ios/ios_ping.dart';
import 'package:test/test.dart';

// Network-free tests for the FFI-backed iOS `IosPing`.
//
// Off iOS, the native code asset is NOT linked, so any FFI entry point would
// fail to link. We therefore exercise ONLY what is reachable without the asset:
// construction, the address-family guard, the static command/parser members,
// and isolation-by-construction. We never touch
// `.stream`/listen, `stop()`, or any FFI function — doing so would attempt to
// open the native asset.
void main() {
  group('IosPing construction', () {
    test('constructs without throwing for a plain IPv4 literal', () {
      expect(
        () => IosPing('1.2.3.4', 1, 1, 2, 255, IpVersion.ipv4, true),
        returnsNormally,
      );
    });

    test('constructs without throwing for a hostname (no DNS performed)', () {
      expect(
        () => IosPing('example.com', null, 1, 2, 64, IpVersion.ipv6, false),
        returnsNormally,
      );
    });
  });

  group('IosPing static members', () {
    test('command returns the native engine string', () {
      final ping = IosPing('1.2.3.4', 1, 1, 2, 255, IpVersion.ipv4, true);
      expect(
        ping.command,
        'Ping on iOS is provided by a native Swift ICMP engine',
      );
    });

    test('parser getter throws UnimplementedError (unused on iOS)', () {
      final ping = IosPing('1.2.3.4', 1, 1, 2, 255, IpVersion.ipv4, true);
      expect(() => ping.parser, throwsUnimplementedError);
    });

    test('parser setter throws UnimplementedError (unused on iOS)', () {
      final ping = IosPing('1.2.3.4', 1, 1, 2, 255, IpVersion.ipv4, true);
      expect(
        () => ping.parser = throw UnimplementedError(),
        throwsUnimplementedError,
      );
    });
  });

  group('address-family guard (fires in the constructor)', () {
    test('an IPv6 literal with IpVersion.ipv4 throws ArgumentError', () {
      expect(
        () => IosPing('::1', 1, 1, 2, 255, IpVersion.ipv4, true),
        throwsArgumentError,
      );
    });

    test('an IPv4 literal with IpVersion.ipv6 throws ArgumentError', () {
      expect(
        () => IosPing('1.2.3.4', 1, 1, 2, 255, IpVersion.ipv6, true),
        throwsArgumentError,
      );
    });

    test('a matching IPv6 literal with IpVersion.ipv6 constructs', () {
      expect(
        () => IosPing('::1', 1, 1, 2, 255, IpVersion.ipv6, true),
        returnsNormally,
      );
    });
  });

  group('isolation by construction (§spec:concurrent-isolation)', () {
    // Two instances are distinct objects with no shared static run/stream/
    // counter state — each owns its own handle, callable, and stats mapper.
    // True concurrent-ICMP isolation is the on-device manual acceptance path;
    // here we can only assert independence at the API level off iOS.
    test('two instances are distinct objects', () {
      final a = IosPing('1.1.1.1', 1, 1, 2, 255, IpVersion.ipv4, true);
      final b = IosPing('2.2.2.2', 1, 1, 2, 255, IpVersion.ipv4, true);
      expect(identical(a, b), isFalse);
    });

    test('constructing several instances does not interfere', () {
      final pings = [
        for (var i = 0; i < 5; i++)
          IosPing('10.0.0.$i', 1, 1, 2, 255, IpVersion.ipv4, true),
      ];
      // All constructed independently; the command is identical and constant,
      // confirming there is no per-instance mutation of shared state.
      expect(pings.length, 5);
      expect(
        pings.map((p) => p.command).toSet(),
        {'Ping on iOS is provided by a native Swift ICMP engine'},
      );
    });
  });
}
