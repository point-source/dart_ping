import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/native_ping.dart';

/// Ping class used to instantiate a ping instance.
/// Spawns an OS ping process when the stream property is listened to
abstract class Ping {
  /// Creates an appropriate Ping instance for the detected platform
  factory Ping(String host,
          {int? count,
          double interval = 1.0,
          double timeout = 2.0,
          int ttl = 255,
          bool ipv6 = false}) =>
      getPing(host, count, interval, timeout, ttl, ipv6);

  /// The command that will be run on the host OS
  String get command;

  /// Stream of [PingData] which spawns a ping process on listen and
  /// kills it on cancellation. The stream closes when the process ends.
  ///
  /// Note that if you cancel the subscription, you will not receive
  /// the ping summary data. If you want to prematurely halt the process
  /// and still receive summary output, use the [stop] method.
  Stream<PingData> get stream;

  /// Kills ping process and closes stream.
  ///
  /// Using [stop] instead of subscription.cancel() allows the ping
  /// summary to output before the stream is closed. If you cancel
  /// your stream subscription, you will not receive summary output.
  Future<bool> stop();
}
