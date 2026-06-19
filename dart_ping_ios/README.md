This package adds iOS support to the [dart_ping](https://pub.dev/packages/dart_ping) package via registration.

The [dart_ping](https://pub.dev/packages/dart_ping) package is required for use.

Created from templates made available by Stagehand under a BSD-style
[license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).

## Version 5.0.0: SPM-only rewrite (migration guide)

Version 5.0.0 is a major change to how iOS support is delivered. The iOS
implementation is now a **native Swift ICMP engine owned in this repository**,
replacing the previous dependency on the third-party `flutter_icmp_ping` plugin.
The good news for your app code: **the public Dart API is unchanged** — existing
code that calls `DartPingIOS.register()` and listens to a `Ping` stream compiles
and runs without edits. The break is purely in how the native code is
distributed.

### SPM-only distribution

5.0.0 is distributed **solely as a Swift Package**. It ships **no CocoaPods
podspec** and requires Flutter's [Swift Package Manager build
mode](https://docs.flutter.dev/packages-and-plugins/swift-package-manager).
An SPM-enabled Flutter app with **no `Podfile`** can add `dart_ping_ios`, build
for iOS, and ping end-to-end. This is the whole point of the rewrite: it unblocks
projects that have moved to SPM, for which the old `flutter_icmp_ping`-backed
release had no path to add iOS ping support.

The minimum supported iOS version is **iOS 13.0**, which matches Flutter's
current minimum-deployment baseline (the `FlutterFramework` Swift package that
plugins depend on targets iOS 13.0), so this package imposes no floor stricter
than Flutter already requires.

### CocoaPods consumers: stay on 4.x

If your project has **not** migrated to SPM, pin `dart_ping_ios` to the `4.x`
line. The previous `flutter_icmp_ping`-backed release remains **published and
resolvable**, so it keeps building and pinging on CocoaPods-based projects with
no changes. Because 5.0.0 is a new **major** version, normal `^4.x` version
constraints will **not** pull the SPM-only rewrite in automatically — you migrate
on your own schedule.

```yaml
# CocoaPods-based project (has a Podfile, not yet on SPM):
dependencies:
  dart_ping_ios: ^4.0.2

# SPM-enabled project (no Podfile):
dependencies:
  dart_ping_ios: ^5.0.0
```

### Compatibility matrix

| `dart_ping_ios` | Native distribution | Build system        | Minimum iOS |
| --------------- | ------------------- | ------------------- | ----------- |
| `4.x`           | CocoaPods podspec   | CocoaPods           | (4.x line)  |
| `5.x`           | Swift Package       | Swift Package Mgr   | 13.0        |

### No special entitlements or extra App Store review

The native engine uses an **unprivileged `SOCK_DGRAM` / `IPPROTO_ICMP` ICMP
socket** — no raw socket, no root, no entitlement. A consuming app therefore
ships unchanged from an App Store packaging standpoint: you do not need to add
any special entitlements or take extra App Store review steps to use iOS ping.

Note that local-network ping does **not** trigger iOS's Local Network privacy
prompt. That prompt applies to LAN-discovery APIs, not to ICMP echo sent to a
routable host, so its absence here is expected and not a defect.

### NAT64 IPv4-literal reachability: on-device acceptance step

NAT64 IPv4-literal synthesis (the default-on `nat64Synthesis` option) has a
**manual on-device acceptance step** that is **not a CI gate** — a live
IPv6-only cellular network cannot be reproduced on hosted runners or the iOS
simulator, so this mirrors #69's deterministic-seam principle (the offline
decision/error seams are covered by network-free `RunnerTests` and Dart tests;
only the live reachability leg is hand-verified).

On an affected device joined to an **IPv6-only cellular network**:

1. Ping an IPv4 literal (e.g. `13.35.27.1`) under `IpVersion.ipv4` with the
   default `nat64Synthesis: true`. Expected: replies with round-trip times and a
   normal run summary — **the same observable result as over Wi-Fi**.
2. Re-run the same ping with `nat64Synthesis: false`. Expected: the prior honest
   `noRoute` error (the un-synthesized failure), never a phantom `unknownHost`
   and never a silent hang.

## Usage

The key to using this package is to import it and call this method before you use dart_ping:

```dart
import 'package:dart_ping_ios/dart_ping_ios.dart';

void main() {
  // Register dart_ping_ios with dart_ping
  // You only need to call this once
  DartPingIOS.register();
}

```

You only need to call this once. I usually do this somewhere in my main method before my app runs.

Here is a simple but full example based on the Flutter counter app:

```dart
import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/material.dart';

void main() {
  // Register dart_ping_ios with dart_ping
  DartPingIOS.register();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartPing Flutter Demo',
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key}) : super(key: key);

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  // Create instance of DartPing
  Ping ping = Ping('google.com', count: 5);
  PingData? _lastPing;

  void _startPing() {
    ping.stream.listen((event) {
      setState(() {
        _lastPing = event;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('DartPing Flutter Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _lastPing?.toString() ?? 'Push the button to begin ping',
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startPing,
        tooltip: 'Start Ping',
        child: Icon(Icons.radar_sharp),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}

```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues
