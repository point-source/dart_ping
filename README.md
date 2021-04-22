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

To print the underlying ping command that will be used
(useful for debugging):

```dart
print('Running command: ${ping.command}')
```

To prematurely halt the process:

```dart
await ping.stop()
```

To override the parser to support an alternative OS language
(Portuguese shown here):

```dart
final parser = PingParser(
    responseStr: RegExp(r'Resposta de'),
    responseRgx: RegExp(r'de (.*): bytes=(\d+) tempo=(\d+)ms TTL=(\d+)'),
    summaryStr: RegExp(r'Perdidos'),
    summaryRgx: RegExp(r'Enviados = (\d+), Recebidos = (\d+), Perdidos = (\d+)'),
    timeoutStr: RegExp(r'host unreachable'),
    unknownHostStr: RegExp(r'A solicitação ping não pôde encontrar o host'));

final ping = Ping('google.com', parser: parser);
```

To override the character encoding to ignore non-utf characters:

```dart
final ping = Ping('google.com', encoding: Utf8Codec(allowMalformed: true));
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues

## Credit

This package contains code from [flutter_icmp_ping](https://pub.dev/packages/flutter_icmp_ping) by [zuvola](zuvola.com), used with permission.
