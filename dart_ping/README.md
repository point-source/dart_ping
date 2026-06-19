Multi-platform network ping utility for Dart applications.

Created from templates made available by Stagehand under a BSD-style
[license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).

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

To use dart_ping on iOS, add the [dart_ping_ios](https://pub.dev/packages/dart_ping_ios) package as a dependency and register the iOS plugin before initializing Ping. For more detailed docs, see the [dart_ping_ios](https://pub.dev/packages/dart_ping_ios) package. Note that the iOS plugin requires the flutter sdk. (this is why it is not integrated into dart_ping directly)

```dart
// Register DartPingIOS
DartPingIOS.register();
// Create ping object with desired args
final ping = Ping('google.com', count: 5);
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

### Address Family (IPv4 / IPv6)

The IP address family is chosen with the `ipVersion` parameter, an **exclusive**
selection: `IpVersion.ipv4` pings over IPv4 only and `IpVersion.ipv6` over IPv6
only. There is no "prefer one family" or dual-stack mode — `IpVersion.ipv4`
*excludes* IPv6 rather than preferring it. The default is `IpVersion.ipv4`.

```dart
// IPv6 only (the system ping is invoked with the -6 family flag on
// Linux/Android; unsupported on Windows and the macOS subprocess path —
// iOS IPv6 is served by dart_ping_ios's native engine)
final ping = Ping('google.com', ipVersion: IpVersion.ipv6);
```

> **Migrating from the `ipv6` boolean:** the old `ipv6: true` / `ipv6: false`
> flag has been replaced by `ipVersion`. Map `ipv6: true` → `ipVersion:
> IpVersion.ipv6`, and `ipv6: false` (or omitting it) → `ipVersion:
> IpVersion.ipv4`. IPv6 remains unsupported on Windows.

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
