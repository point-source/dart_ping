import 'dart:async';

import 'package:dart_ping/src/models/ping_data.dart';

abstract class BasePing {
  BasePing(this.host, this.count, this.interval, this.timeout, this.ipv6) {
    controller = StreamController<PingData>(
        onListen: onListen,
        onCancel: _onCancel,
        onPause: () => subscription.pause,
        onResume: () => subscription.resume);
  }

  String host;
  int count;
  double interval;
  double timeout;
  bool ipv6;
  StreamController<PingData> controller;
  StreamSubscription<PingData> subscription;

  Stream<PingData> get stream => controller.stream;

  void onListen();

  void _onCancel() {
    subscription.cancel();
    subscription = null;
  }

  void stop() => controller.close();
}
