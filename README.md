## Dart Ping

dart_ping is a multi-platform network ping utility for Dart applications.

It is available for use via the [pub.dev package repository](https://pub.dev/packages/dart_ping)

### iOS Compatibility

In order to provide compatibility on iOS (via Flutter Method Channels) while retaining native dart support, the package is split into two parts:

[dart_ping](dart_ping) is the main package which supports Windows, Mac, Linux, and Android natively without additional binaries

[dart_ping_ios](dart_ping_ios) is a plugin which adds cocoa dependencies to support ping on iOS systems. Using this plugin requires the Flutter SDK to be added to your dart project.

### Windows Compatibility

When using this package with Flutter for Windows, release builds [may not work as intended](https://github.com/point-source/dart_ping/issues/16). This is due to a [known issue](https://github.com/dart-lang/sdk/issues/39945) with the Flutter framework on windows. There is [a workaround described here.](https://github.com/dart-lang/sdk/issues/39945#issuecomment-870428151)