import 'dart:convert';
import 'dart:io';

import 'address_family.dart';
import 'ip_version.dart';
import 'models/ping_data.dart';
import 'models/ping_parser.dart';
import 'ping/linux_ping.dart';
import 'ping/mac_ping.dart';
import 'ping/windows_ping.dart';

/// Ping class used to instantiate a ping instance.
/// Spawns an OS ping process when the stream property is listened to
abstract class Ping {
  /// Creates an appropriate Ping instance for the detected platform
  factory Ping(
    /// Hostname, domain, or IP which you would like to ping
    String host, {
    /// How many times the host should be pinged before the process ends
    int? count,

    /// Delay between ping attempts
    int interval = 1,

    /// How long (in seconds) to wait for a ping to return before marking it as lost
    int timeout = 2,

    /// How many network hops the packet should travel before expiring
    int ttl = 255,

    /// The IP address family to ping with — an explicit, exclusive selection
    /// (see [IpVersion]). Defaults to [IpVersion.ipv4] (IPv4 only). IPv6 is
    /// not supported on Windows.
    IpVersion ipVersion = IpVersion.ipv4,

    /// Custom parser to interpret ping process output
    /// Useful for non-english based platforms
    PingParser? parser,

    /// Encoding used to decode character codes from process output
    Encoding encoding = const Utf8Codec(),

    /// Force the console process to use codepage 437 (DOS Latin US)
    ///
    /// Under the hood, this appends the ping command with the `chcp` command
    /// like so: `chcp 437 && ping {opts}`
    bool forceCodepage = false,
  }) {
    // Synchronous address-family guard: if [host] is a literal IP address, its
    // family MUST match the selected [ipVersion]. This runs before any platform
    // dispatch (including the iOS factory path) and before any stream/process
    // starts. A hostname (literalFamily == null) or a matching literal falls
    // straight through to the platform switch unchanged — no DNS is performed.
    final literalFamily = ipLiteralFamily(host);
    if (literalFamily != null && literalFamily != ipVersion) {
      throw ArgumentError.value(
        host,
        'host',
        'Address family mismatch: the target is an '
            '${literalFamily == IpVersion.ipv6 ? 'IPv6' : 'IPv4'} literal but '
            'ipVersion is '
            '${ipVersion == IpVersion.ipv6 ? 'IpVersion.ipv6' : 'IpVersion.ipv4'}. '
            'A literal IP address must match the selected IP version',
      );
    }

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
          ipVersion,
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
          ipVersion,
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
          ipVersion,
          parser: parser,
          encoding: encoding,
          forceCodepage: forceCodepage,
        );
      case 'ios':
        Function? ios = iosFactory;
        if (iosFactory != null) {
          return ios!(
            host,
            count,
            interval,
            timeout,
            ttl,
            ipVersion,
            parser,
            encoding,
          );
        }
        throw UnimplementedError(
          'iOS support has not been enabled. Please see the docs at https://pub.dev/packages/dart_ping',
        );
      default:
        throw UnimplementedError('Ping not supported on this platform');
    }
  }

  static Ping Function(
    String host,
    int? count,
    int interval,
    int timeout,
    int ttl,
    IpVersion ipVersion,
    PingParser? parser,
    Encoding encoding,
  )? iosFactory;

  /// Parser used to interpret ping process output
  late PingParser parser;

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
