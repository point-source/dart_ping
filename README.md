## Dart Ping

dart_ping is a multi-platform network ping utility for Dart applications.

It is available for use via the [pub.dev package repository](https://pub.dev/packages/dart_ping)

### iOS Compatibility

iOS cannot use the same native subprocess approach as the other platforms, so the repository is split into two packages:

[dart_ping](dart_ping) is the main package which supports Windows, macOS, Linux, and Android natively without additional binaries.

[dart_ping_ios](dart_ping_ios) is a Flutter plugin that adds iOS support through a native Swift ICMP engine distributed via Swift Package Manager (SPM). As of version 5.0.0 it ships no CocoaPods podspec and requires Flutter's SPM build mode; using it requires the Flutter SDK. CocoaPods-based projects that have not migrated to SPM should stay on the `4.x` line. See the [dart_ping_ios README](dart_ping_ios) for the SPM requirements and the 4.x → 5.x migration guide.
