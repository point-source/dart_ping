# dart_ping example

A Flutter demo app for [`dart_ping`](../). It pings a host and streams the
per-probe responses and run summary to the screen.

iOS support is built directly into `dart_ping` (an FFI-backed native ICMP
engine compiled by a build hook) — the app depends on **only** `dart_ping`,
adds no second package, and calls no `register()`. Build it for iOS under
Flutter's Swift Package Manager mode with **no CocoaPods Podfile**.

```sh
flutter pub get
flutter run            # on a simulator or device
```

The iOS `RunnerTests` target hosts the deterministic, network-free Swift
ICMP framing/parse tests, compiled against `../native/ICMPPacket.swift`
(see `.github/workflows/ci.yml`, the `ios-swift` job).

A pure-Dart CLI example lives alongside at
[`dart_ping_example.dart`](dart_ping_example.dart).
