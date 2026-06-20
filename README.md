# Dart Ping

Multi-platform network ping utility for Dart and Flutter applications, available
via the [pub.dev package repository](https://pub.dev/packages/dart_ping).

## One package, every platform

There is **one package for every platform** — add only `dart_ping`:

- **Windows, macOS, Linux, Android** are served natively by the `ping`
  subprocess — no extra binaries.
- **iOS** is served by a bundled native Swift ICMP engine driven over
  `dart:ffi`. The engine is compiled into the app by a Dart build hook **only
  when the build target is iOS**. It builds under Flutter's Swift Package Manager
  (SPM) mode with **no CocoaPods `Podfile`**, and requires the `dart_ping` 10.x
  SDK floor (Dart 3.10 / Flutter 3.38).

Pure-Dart consumers (CLI, server) are unaffected: with no iOS target, no Swift
is compiled and no Flutter SDK is required.

> **Migrating from `dart_ping_ios`:** remove the `dart_ping_ios` dependency,
> delete the `DartPingIOS.register()` call, and raise your SDK floor to the
> `dart_ping` 10.x baseline — no other source change, since the public `Ping`
> API is otherwise unchanged. Prior `dart_ping_ios` releases remain published on
> pub.dev for consumers who cannot adopt the raised floor; this repository no
> longer carries that package. See the [CHANGELOG](CHANGELOG.md) for the full
> 10.0.0 migration guide (including the sealed `PingEvent` stream and the
> `ipv6` → `IpVersion` change).

## Usage

A simple usage example:

```dart
import 'package:dart_ping/dart_ping.dart';

void main() async {
  // Create ping object with desired args
  final ping = Ping('google.com', count: 5);

  // Begin ping process and listen for output
  ping.stream.listen((event) {
    print(event);
  });
}
```

Instead of listening to a stream, you can perform a single ping and immediately return the result like so:

```dart
final result = await Ping('google.com', count: 1).stream.first;
```

To print the underlying ping command that will be used
(useful for debugging):

```dart
print('Running command: ${ping.command}')
```

To prematurely halt the process:

```dart
await ping.stop()
```

### The event stream

`Ping.stream` is a `Stream<PingEvent>` — a sealed union with three subtypes.
Branch on the type with an exhaustive `switch`:

```dart
ping.stream.listen((event) {
  switch (event) {
    case PingResponse(): // a successful probe reply (seq, ttl, time, ip)
    case PingError():    // a probe/run error (may carry seq/ip)
    case PingSummary():  // the terminal run summary — the final event
  }
});
```

Every probe event also carries a nullable `RoundTripStats? stats` snapshot
(min/avg/max/stddev/jitter so far), and `PingSummary` exposes both `stats` and a
derived `packetLoss` getter, so you can drive a live latency/loss view without
waiting for the summary.

### Selecting a network interface

`Ping(host, interface: ...)` binds the ping to a specific interface, accepting either an interface name (e.g. `eth0`) or a local source IP address (e.g. `192.168.1.5`). To discover the host's available interfaces, use `listNetworkInterfaces()` and feed one back into a `Ping`:

```dart
final interfaces = await listNetworkInterfaces();
// Pick one — by name or by a source address — then bind a ping to it.
final ping = Ping('dart.dev', interface: interfaces.first.name);
await for (final event in ping.stream) {
  print(event);
}
```

On Windows you must pass back a source address (e.g. `interfaces.first.addresses.first.address`), not the name, because Windows `ping` binds only by source address; a bare interface name is rejected there. A source address round-trips on every platform.

### Address Family (IPv4 / IPv6)

The IP address family is chosen with the `ipVersion` parameter, an **exclusive**
selection: `IpVersion.ipv4` pings over IPv4 only and `IpVersion.ipv6` over IPv6
only. There is no "prefer one family" or dual-stack mode — `IpVersion.ipv4`
*excludes* IPv6 rather than preferring it. The default is `IpVersion.ipv4`.

```dart
// IPv6 only (the system ping is invoked with the -6 family flag on
// Linux/Android; unsupported on Windows and the macOS subprocess path —
// iOS IPv6 is served by dart_ping's own native engine)
final ping = Ping('google.com', ipVersion: IpVersion.ipv6);
```

> **Migrating from the `ipv6` boolean:** the old `ipv6: true` / `ipv6: false`
> flag has been replaced by `ipVersion`. Map `ipv6: true` → `ipVersion:
> IpVersion.ipv6`, and `ipv6: false` (or omitting it) → `ipVersion:
> IpVersion.ipv4`. IPv6 remains unsupported on Windows.

### IPv6-only networks (NAT64)

On an IPv6-only cellular network (NAT64/DNS64), an IPv4 literal such as `1.1.1.1` can be unreachable unless the platform synthesizes an IPv6 path to it. `Ping` exposes a `nat64Synthesis` option that is enabled by default, so an IPv4 literal keeps working on iOS without any code change. The active synthesis happens on iOS (via `dart_ping`'s native engine); on the subprocess platforms (Windows, macOS, Linux, Android) the option is a no-op that leaves the ping command unchanged. Pass `nat64Synthesis: false` to opt out and restore raw pass-through.

### Non-English Language Support

To support OS languages other than English, you can override the parser (Portuguese shown here):

```dart
final parser = PingParser(
    responseRgx: RegExp(r'de (?<ip>.*): bytes=(?:\d+) tempo=(?<time>\d+)ms TTL=(?<ttl>\d+)'),
    summaryRgx: RegExp(r'Enviados = (?<tx>\d+), Recebidos = (?<rx>\d+), Perdidos = (?:\d+)'),
    timeoutRgx: RegExp(r'host unreachable'),
    timeToLiveRgx: RegExp(r''),
    unknownHostStr: RegExp(r'A solicitação ping não pôde encontrar o host'),
  );

final ping = Ping('google.com', parser: parser);
```

On Windows installations, you can force the codepage (437) of the console instead of providing a custom parser:

```dart
final ping = Ping('google.com', forceCodepage: true);
```

To override the character encoding to ignore non-utf characters:

```dart
final ping = Ping('google.com', encoding: Utf8Codec(allowMalformed: true));
```

### macOS Release Build with App Sandbox

When building in release mode with [app sandbox](https://developer.apple.com/documentation/security) enabled, you must ensure you add the following entitlements to the Release.entitlements file in your macos folder:

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues
