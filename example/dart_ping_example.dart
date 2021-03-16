import 'package:dart_ping/dart_ping.dart';

void main() async {
  final ping = Ping('google.com', count: 3, interval: 1);
  ping.stream.listen((event) {
    print(event);
  });
}
