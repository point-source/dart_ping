This package adds iOS support to the [dart_ping](https://pub.dev/packages/dart_ping) package via registration.

The [dart_ping](https://pub.dev/packages/dart_ping) is required for use.

Created from templates made available by Stagehand under a BSD-style
[license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).

## Usage

A simple usage example:

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
      title: 'DartPing iOS Demo',
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
        title: Text('DartPing iOS Demo'),
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
        tooltip: 'Increment',
        child: Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/point-source/dart_ping/issues

## Credit

This package contains code from [flutter_icmp_ping](https://pub.dev/packages/flutter_icmp_ping) by [zuvola](zuvola.com), used with permission.
