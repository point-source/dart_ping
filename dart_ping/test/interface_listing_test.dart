import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/interface_listing.dart';
import 'package:test/test.dart';

void main() {
  group('listNetworkInterfaces: ', () {
    test('is exported and returns a List<NetworkInterface>', () async {
      // Reachable from the public entrypoint. includeLoopback keeps a result
      // present on minimal hosts; assert only the shape, never a count.
      final result = await listNetworkInterfaces(includeLoopback: true);
      expect(result, isA<List<NetworkInterface>>());
    });

    test('each interface has the right shape and round-trips into Ping',
        () async {
      final interfaces = await listNetworkInterfaces(includeLoopback: true);

      // No-op-but-passing if the host reports zero interfaces.
      for (final iface in interfaces) {
        expect(iface.name, isA<String>());
        expect(iface.name, isNotEmpty);
        expect(iface.addresses, isA<List<InternetAddress>>());

        // The loop closes: a returned name feeds back into a Ping selection.
        expect(
          () => Ping('127.0.0.1', interface: iface.name, count: 1),
          returnsNormally,
        );

        // And so does a returned address string, when one is present.
        if (iface.addresses.isNotEmpty) {
          final addr = iface.addresses.first.address;
          expect(
            () => Ping('127.0.0.1', interface: addr, count: 1),
            returnsNormally,
          );
        }
      }
    });
  });

  group('listNetworkInterfaces failure: ', () {
    late NetworkInterfaceLister original;

    setUp(() => original = networkInterfaceLister);
    tearDown(() => networkInterfaceLister = original);

    test('propagates the enumeration error instead of swallowing it', () {
      final boom = const SocketException('interface enumeration failed');
      networkInterfaceLister = ({
        bool includeLoopback = false,
        bool includeLinkLocal = false,
        InternetAddressType type = InternetAddressType.any,
      }) =>
          Future<List<NetworkInterface>>.error(boom);

      expectLater(
        listNetworkInterfaces(),
        throwsA(same(boom)),
      );
    });
  });
}
