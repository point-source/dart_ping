import 'dart:io';

import 'package:dart_ping/src/ip_version.dart';

/// Returns the IP address family of [host] when it is a literal IP address,
/// or null when [host] is not an IP literal (i.e. a hostname).
///
/// This is parse-only: it performs NO DNS resolution. A hostname therefore
/// always returns null and is never classified.
IpVersion? ipLiteralFamily(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null) return null;
  switch (address.type) {
    case InternetAddressType.IPv4:
      return IpVersion.ipv4;
    case InternetAddressType.IPv6:
      return IpVersion.ipv6;
    default:
      return null; // unix socket / other — not an IP literal family
  }
}

/// Throws an [ArgumentError] when [host] is a literal IP address whose family
/// contradicts the selected [ipVersion] (both directions). A hostname or a
/// matching literal returns normally — no DNS is performed
/// (§spec:address-family-mismatch-validation).
///
/// Centralised here so every entry point — the [Ping] factory, the core
/// platform classes (via `BasePing`), and the iOS `DartPingIOS` bridge — fails
/// fast with the identical error, instead of the guard living only in the
/// factory and being bypassed by direct construction.
void validateAddressFamily(String host, IpVersion ipVersion) {
  final literalFamily = ipLiteralFamily(host);
  if (literalFamily != null && literalFamily != ipVersion) {
    throw ArgumentError.value(
      host,
      'host',
      'Address family mismatch: the target is an ${literalFamily.label} '
          'literal but ipVersion is $ipVersion. '
          'A literal IP address must match the selected IP version',
    );
  }
}
