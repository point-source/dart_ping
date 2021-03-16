import 'dart:async';

import 'package:dart_ping/src/models/ping_data.dart';

abstract class BasePing {
  BasePing(this.host, this.count, this.interval, this.timeout, this.ipv6) {
    controller =
        StreamController<PingData>(onListen: onListen, onCancel: onCancel);
  }

  String host;
  int count;
  double interval;
  double timeout;
  bool ipv6;
  StreamController<PingData> controller;

  Stream<PingData> get stream => controller.stream;

  Future<void> onListen();

  Future<void> onCancel() async => await stop();

  Future<void> stop() async => await controller.close();
}
