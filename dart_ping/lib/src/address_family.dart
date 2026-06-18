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
