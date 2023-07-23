import 'dart:convert';
import 'dart:io';

import 'package:dart_ping/src/ping_interface.dart';
import 'package:dart_ping/src/models/ping_parser.dart';
import 'package:dart_ping/src/ping/linux_ping.dart';
import 'package:dart_ping/src/ping/mac_ping.dart';
import 'package:dart_ping/src/ping/windows_ping.dart';

// ignore: long-parameter-list
Ping getPing(
  String host,
  int? count,
  int interval,
  int timeout,
  int ttl,
  bool ipv6,
  PingParser? parser,
  Encoding encoding,
  bool forceCodepage,
) {
  switch (Platform.operatingSystem) {
    case 'android':
    case 'fuchsia':
    case 'linux':
      return PingLinux(
        host,
        count,
        interval,
        timeout,
        ttl,
        ipv6,
        parser: parser,
        encoding: encoding,
      );
    case 'macos':
      return PingMac(
        host,
        count,
        interval,
        timeout,
        ttl,
        ipv6,
        parser: parser,
        encoding: encoding,
      );
    case 'windows':
      return PingWindows(
        host,
        count,
        interval,
        timeout,
        ttl,
        ipv6,
        parser: parser,
        encoding: encoding,
        forceCodepage: forceCodepage,
      );
    default:
      throw UnimplementedError('Ping not supported on this platform');
  }
}
