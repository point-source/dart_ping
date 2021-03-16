import 'package:dart_ping/dart_ping.dart';

void main() async {
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
  await ping.stop();
}
