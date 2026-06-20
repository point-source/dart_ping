import 'dart:async';

import 'package:dart_ping/dart_ping.dart';
import 'package:flutter/material.dart';

void main() {
  // iOS support is built into dart_ping and auto-wires — no second package and
  // no register() call. Just construct Ping(...) and it works on iOS too.
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
  final List<PingEvent> _events = [];
  final TextEditingController _controller =
      TextEditingController(text: 'google.com');
  final TextEditingController _ttlController = TextEditingController(text: '64');
  StreamSubscription<PingEvent>? _subscription;

  void _startPing() {
    final ttl = int.tryParse(_ttlController.text) ?? 64;

    // Create instance of DartPing
    final ping = Ping(_controller.text, count: 5, ttl: ttl);
    debugPrint('Running command: ${ping.command}');

    // Drop any previous run before starting a new one so taps don't stack
    // subscriptions all feeding setState.
    _subscription?.cancel();

    setState(() {
      _events.clear();
    });

    _subscription = ping.stream.listen((event) {
      setState(() {
        _events.add(event);
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    _ttlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final output = _events.isEmpty
        ? 'Push the button to begin ping'
        : _events.map((e) => e.toString()).join('\n');

    return Scaffold(
      appBar: AppBar(
        title: const Text('DartPing Flutter Demo'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(labelText: 'Host'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: TextField(
              controller: _ttlController,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'TTL'),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Text(output),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startPing,
        tooltip: 'Start Ping',
        child: const Icon(Icons.radar_sharp),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
