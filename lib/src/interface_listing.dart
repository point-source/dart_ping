import 'dart:io';

/// Signature of [NetworkInterface.list]; the seam tests override.
typedef NetworkInterfaceLister = Future<List<NetworkInterface>> Function({
  bool includeLoopback,
  bool includeLinkLocal,
  InternetAddressType type,
});

/// Enumeration backend, defaulting to the real SDK call. Tests override
/// this (via a `package:dart_ping/src/interface_listing.dart` import) to
/// exercise the failure path, then restore it. Not part of the public
/// `package:dart_ping/dart_ping.dart` surface.
NetworkInterfaceLister networkInterfaceLister = NetworkInterface.list;

/// Lists the network interfaces available on the current host.
///
/// Each returned [NetworkInterface] is identified well enough to be fed
/// back into a [Ping]'s `interface` value: use its `name` (e.g. `eth0`)
/// or one of its `addresses` (`InternetAddress.address`, e.g.
/// `192.168.1.5`) as the selection.
///
/// On Windows the OS `ping` binds only by source address, so a bare
/// interface `name` is rejected with a catchable [UnimplementedError];
/// on Windows pass back one of the interface's `addresses`
/// (`InternetAddress.address`), not its name. The address form
/// round-trips on every platform; the name form only where the OS binds
/// by name (Linux/Android, macOS).
///
/// Built on `dart:io`'s [NetworkInterface.list] — no `ifconfig`/`ip`/
/// `ipconfig` text parsing. The [includeLoopback], [includeLinkLocal] and
/// [type] arguments are forwarded unchanged.
///
/// A failure to enumerate is propagated to the caller as a rejected
/// future (it is NOT swallowed or turned into an empty list).
Future<List<NetworkInterface>> listNetworkInterfaces({
  bool includeLoopback = false,
  bool includeLinkLocal = false,
  InternetAddressType type = InternetAddressType.any,
}) =>
    networkInterfaceLister(
      includeLoopback: includeLoopback,
      includeLinkLocal: includeLinkLocal,
      type: type,
    );
