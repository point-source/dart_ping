import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/material.dart';

void main() {
  // Register dart_ping_ios with dart_ping
  DartPingIOS.register();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'DartPing Flutter Demo',
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  MyHomePageState createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
  PingData? _lastPing;
  final TextEditingController _controller =
      TextEditingController(text: 'google.com');

  void _startPing() {
    // Create instance of DartPing
    final ping = Ping(_controller.text, count: 5);
    print('Running command: ${ping.command}');
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
        title: const Text('DartPing Flutter Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: TextField(
                controller: _controller,
                textAlign: TextAlign.center,
              ),
            ),
            Text(
              _lastPing?.toString() ?? 'Push the button to begin ping',
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startPing,
        tooltip: 'Start Ping',
        child: const Icon(Icons.radar_sharp),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
