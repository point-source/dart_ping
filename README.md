Multi-platform network ping utility for Dart applications.

Created from templates made available by Stagehand under a BSD-style
[license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).

## Usage

A simple usage example:

```dart
import 'package:dart_ping/dart_ping.dart';

void main() async {
  final ping = Ping('google.com', count: 3, interval: 1);
  ping.stream.listen((event) {
    print(event);
  });
}
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues

## Credit

This package contains code from [flutter_icmp_ping](https://pub.dev/packages/flutter_icmp_ping) by [zuvola](zuvola.com), used with permission.
