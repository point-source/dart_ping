import 'package:dart_ping/src/dart_ping_base.dart';
import 'package:dart_ping/src/ios_ping.dart';
import 'package:dart_ping/src/linux_ping.dart';
import 'package:dart_ping/src/windows_ping.dart';
import 'package:flutter/foundation.dart';

Ping getPing(
    String host, int count, double interval, double timeout, bool ipv6) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return PingLinux(host, count, interval, timeout, ipv6);
    case TargetPlatform.iOS:
      return PingiOS(host, count, interval, timeout, ipv6);
    case TargetPlatform.windows:
      return PingWindows(host, count, interval, timeout, ipv6);
    default:
      throw UnimplementedError('Could not determine target platform');
  }
}
