import 'dart:io';

import 'package:dart_ping/src/dart_ping_base.dart';
import 'package:dart_ping/src/models/regex_parser.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';

Ping getPing(String host, int? count, double interval, double timeout, int ttl,
    bool ipv6, RegexParser? parser) {
  switch (Platform.operatingSystem) {
    case 'android':
    case 'fuchsia':
    case 'linux':
      return PingLinux(host, count, interval, timeout, ttl, ipv6,
          parser: parser);
    case 'macos':
      return PingMac(host, count, interval, timeout, ttl, ipv6, parser: parser);
    case 'windows':
      return PingWindows(host, count, interval, timeout, ttl, ipv6,
          parser: parser);
    default:
      throw UnimplementedError('Ping not supported on this platform');
  }
}
