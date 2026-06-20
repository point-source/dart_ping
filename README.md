## Dart Ping

dart_ping is a multi-platform network ping utility for Dart applications.

It is available for use via the [pub.dev package repository](https://pub.dev/packages/dart_ping)

### iOS Compatibility

iOS cannot use the same native subprocess approach as the other platforms, so
[dart_ping](dart_ping) carries a native Swift ICMP engine and drives it over
`dart:ffi`. The engine is compiled into the app by a Dart build hook **only when
the build target is iOS**, so there is **one package for every platform**:

- **Windows, macOS, Linux, Android** are served natively by the `ping`
  subprocess — no extra binaries.
- **iOS** is served by the bundled native Swift engine. Add **only `dart_ping`**
  — no second package, no `register()` call, and no `dependency_overrides`. It
  builds under Flutter's Swift Package Manager (SPM) mode with **no CocoaPods
  Podfile**.

Pure-Dart consumers (CLI, server) are unaffected: with no iOS target, no Swift
is compiled and no Flutter SDK is required.

**Migrating from `dart_ping_ios`:** remove the `dart_ping_ios` dependency, delete
the `DartPingIOS.register()` call, and raise your SDK floor to the
`dart_ping` 10.x baseline — no other source change, since the public `Ping` API
is otherwise unchanged. The prior `dart_ping_ios` releases remain published on
pub.dev for consumers who cannot adopt the raised floor; the repository no longer
carries that package. See the [dart_ping README](dart_ping) and CHANGELOG for the
full migration guide.

### IPv6-only networks (NAT64)

On an IPv6-only cellular network (NAT64/DNS64), an IPv4 literal such as `1.1.1.1` can be unreachable unless the platform synthesizes an IPv6 path to it. `Ping` exposes a `nat64Synthesis` option that is enabled by default, so an IPv4 literal keeps working on iOS without any code change. The active synthesis happens on iOS (via `dart_ping`'s native engine); on the subprocess platforms (Windows, macOS, Linux, Android) the option is a no-op that leaves the ping command unchanged. Pass `nat64Synthesis: false` to opt out and restore raw pass-through.
