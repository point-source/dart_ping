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
