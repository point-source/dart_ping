import 'package:dart_ping/dart_ping.dart';

void main() {
  final ping = Ping(
    'google.com',
    count: 3,
    timeout: 1,
    interval: 1,
    ipv6: false,
  );
  ping.stream.listen((event) {
    print(event);
  });
}
