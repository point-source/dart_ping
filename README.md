Multi-platform network ping utility for Dart applications.

Created from templates made available by Stagehand under a BSD-style
[license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).

## Usage

A simple usage example:

```dart
import 'package:dart_ping/dart_ping.dart';

// Create ping object with desired args
final ping = Ping('google.com', count: 5);

// Begin ping process and listen for output
ping.stream.listen((event) {
  print(event);
});

// Waiting for ping to output first two results
// Not needed in actual use. For example only
await Future.delayed(Duration(seconds: 2));

// Stop the ping prematurely and output a summary
// Make sure you do not call this before listening to the stream!
await ping.stop();
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues

## Credit

This package contains code from [flutter_icmp_ping](https://pub.dev/packages/flutter_icmp_ping) by [zuvola](zuvola.com), used with permission.
