import 'dart:io';

import 'package:dart_ping/src/dart_ping_base.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';

Ping getPing(
    String host, int count, double interval, double timeout, bool ipv6) {
  switch (Platform.operatingSystem) {
    case 'android':
    case 'fuchsia':
    case 'linux':
      return PingLinux(host, count, interval, timeout, ipv6);
    case 'macos':
      return PingMac(host, count, interval, timeout, ipv6);
    case 'windows':
      return PingWindows(host, count, interval, timeout, ipv6);
    default:
      throw UnimplementedError('Ping not supported on this platform');
  }
}
