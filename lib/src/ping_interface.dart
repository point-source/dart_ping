import 'dart:convert';
import 'dart:io';

import 'address_family.dart';
import 'ip_version.dart';
import 'models/ping_event.dart';
import 'models/ping_parser.dart';
import 'ping/ios/ios_ping.dart';
import 'ping/linux_ping.dart';
import 'ping/mac_ping.dart';
import 'ping/windows_ping.dart';

/// Rejects any interface selection on iOS.
///
/// The iOS native engine exposes no interface binding, so selecting one (by
/// interface name OR source address) cannot be honored. Throws an explicit
/// [UnimplementedError] when [interface] is a non-empty selection; a null or
/// empty value means "no selection" and is a no-op.
///
/// Extracted as a top-level function so the rejection can be unit-tested on
/// any host, since the `Ping()` factory's `'ios'` branch is unreachable off
/// iOS.
void throwIfInterfaceUnsupportedOnIos(String? interface) {
  if (interface != null && interface.isNotEmpty) {
    throw UnimplementedError('Interface selection is not supported on iOS');
  }
}

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
    /// (see [IpVersion]). Defaults to [IpVersion.ipv4] (IPv4 only).
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

    /// Network interface to originate pings from.
    ///
    /// This single value accepts EITHER an interface *name* (e.g. `eth0` /
    /// `en0`) OR a local source *IP address* (e.g. `192.168.1.5`). It is named
    /// for the user's mental model — "the path to ping from" — even though it
    /// also accepts a source address; each platform maps it onto the binding
    /// flag(s) its `ping` supports (Linux/Android: both; macOS: both; Windows:
    /// address only). Omitting it leaves the produced command unchanged.
    String? interface,

    /// Whether the platform may reach an IPv4 literal on an IPv6-only
    /// (NAT64/DNS64) network via the platform's own address synthesis
    /// (§spec:nat64-option).
    ///
    /// Defaults to enabled. It is actively honored ONLY on iOS, where the
    /// native engine synthesizes an IPv6 path to an IPv4 literal. On the
    /// subprocess platforms (Linux/Android, macOS, Windows) it is a documented
    /// NO-OP carried purely for cross-platform option parity — it never alters
    /// the produced command and never raises an error. Disabling it restores
    /// raw pass-through: the family-pinned resolve with no synthesis.
    bool nat64Synthesis = true,
  }) {
    // Synchronous address-family guard: if [host] is a literal IP address, its
    // family MUST match the selected [ipVersion]. This runs before any platform
    // dispatch (including the iOS factory path) and before any stream/process
    // starts. The same guard also runs inside each platform constructor (via
    // [validateAddressFamily]) so direct construction cannot bypass it; checking
    // here as well keeps the failure at the documented `Ping(...)` entry point.
    // A hostname or a matching literal falls straight through — no DNS is done.
    validateAddressFamily(host, ipVersion);

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
          interface: interface,
          nat64Synthesis: nat64Synthesis,
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
          interface: interface,
          nat64Synthesis: nat64Synthesis,
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
          interface: interface,
          nat64Synthesis: nat64Synthesis,
        );
      case 'ios':
        throwIfInterfaceUnsupportedOnIos(interface);
        // iOS dispatches to the FFI-backed implementation directly, exactly as
        // the other branches construct their platform `Ping`s. No `iosFactory`
        // indirection and no `register()` step — `dart:ffi` is part of the core
        // SDK, so referencing `IosPing` from shared Dart code pulls no native
        // symbols into non-iOS builds; the native library is only *opened* on
        // this branch, which only runs on iOS (§spec:ios-auto-wiring).
        return IosPing(
          host,
          count,
          interval,
          timeout,
          ttl,
          ipVersion,
          nat64Synthesis,
        );
      default:
        throw UnimplementedError('Ping not supported on this platform');
    }
  }

  /// Parser used to interpret ping process output
  late PingParser parser;

  /// The command that will be run on the host OS
  String get command;

  /// Stream of [PingEvent]s which spawns a ping process on listen and
  /// kills it on cancellation. The stream closes when the process ends.
  ///
  /// Each event is one variant of the sealed [PingEvent] union — a successful
  /// probe [PingResponse], a probe/run [PingError], or the terminal
  /// [PingSummary]. Consumers branch with an exhaustive `switch`; the terminal
  /// [PingSummary] is the final event and is identifiable by type alone
  /// (`is PingSummary`).
  ///
  /// Note that if you cancel the subscription, you will not receive
  /// the ping summary data. If you want to prematurely halt the process
  /// and still receive summary output, use the [stop] method.
  Stream<PingEvent> get stream;

  /// Kills ping process and closes stream.
  ///
  /// Using [stop] instead of subscription.cancel() allows the ping
  /// summary to output before the stream is closed. If you cancel
  /// your stream subscription, you will not receive summary output.
  Future<bool> stop();
}
