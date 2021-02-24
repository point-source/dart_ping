import 'package:dart_ping/dart_ping.dart';

import 'ping_stub.dart'
    if (dart.library.io) 'package:dart_ping/src/native_ping.dart';

abstract class Ping {
  factory Ping(String host,
          {int count, double interval, double timeout, bool ipv6}) =>
      getPing(host, count, interval, timeout, ipv6);

  Stream<PingData> get stream;

  void stop();
}
