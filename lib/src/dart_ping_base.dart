import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/src/native_ping.dart';

/// Ping class used to instantiate a ping instance.
/// Spawns an OS ping process when the stream property is listened to
abstract class Ping {
  /// Creates an appropriate Ping instance for the detected platform
  factory Ping(String host,
          {int count, double interval, double timeout, bool ipv6}) =>
      getPing(host, count, interval, timeout, ipv6);

  /// Stream of [PingData] which spawns a ping process on listen and
  /// kills it on cancellation. The stream closes when the process ends.
  Stream<PingData> get stream;

  /// Kills ping process and closes stream.
  Future<void> stop();
}
