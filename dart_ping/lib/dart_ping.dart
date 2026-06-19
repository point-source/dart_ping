library;

export 'package:dart_ping/src/models/ping_event.dart';
export 'package:dart_ping/src/models/round_trip_stats.dart';
export 'package:dart_ping/src/ip_version.dart';
export 'package:dart_ping/src/address_family.dart'
    show ipLiteralFamily, validateAddressFamily;
export 'package:dart_ping/src/ping_interface.dart';
export 'package:dart_ping/src/models/ping_parser.dart';
export 'package:dart_ping/src/interface_listing.dart' show listNetworkInterfaces;
// Note: `dart:io` types (NetworkInterface, InternetAddress, ...) are NOT
// re-exported. `listNetworkInterfaces()` returns `List<NetworkInterface>`;
// consumers import `dart:io` directly to name those types, which avoids
// ambiguous-import conflicts for the many callers that already import it.
