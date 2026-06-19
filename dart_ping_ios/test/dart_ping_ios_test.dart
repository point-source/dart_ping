import 'dart:async';
import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the iOS channel bridge (`DartPingIOS`) without a native engine:
/// the `MethodChannel` is mocked to capture `start`/`stop` calls, and native
/// events are injected onto the `EventChannel` to drive the stream lifecycle.
/// The event-mapping itself is covered separately by `ping_event_mapper_test`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'dart_ping_ios';
  const eventChannelName = 'dart_ping_ios/events';
  const codec = StandardMethodCodec();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> methodCalls;

  /// Pushes a native event onto the shared EventChannel, as the Swift side
  /// would. Only delivered once a [DartPingIOS] stream has a listener.
  void emitNativeEvent(Object? event) {
    messenger.handlePlatformMessage(
      eventChannelName,
      codec.encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  setUp(() {
    methodCalls = [];
    // Capture start/stop invocations on the method channel.
    messenger.setMockMethodCallHandler(
      const MethodChannel(methodChannelName),
      (call) async {
        methodCalls.add(call);
        return null;
      },
    );
    // The EventChannel performs a listen/cancel handshake over its own
    // (event-named) method channel; acknowledge it so the broadcast stream
    // activates.
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      (call) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(methodChannelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(eventChannelName),
      null,
    );
  });

  MethodCall callNamed(String name) =>
      methodCalls.firstWhere((c) => c.method == name);

  test('command describes the native engine', () {
    final ping = DartPingIOS('host', 1, 1, 2, 64, IpVersion.ipv4, true);
    expect(ping.command, contains('native Swift ICMP engine'));
  });

  group('direct construction enforces the address-family guard', () {
    test('an IPv4 literal with IpVersion.ipv6 throws ArgumentError', () {
      expect(
        () => DartPingIOS('1.2.3.4', 1, 1, 2, 64, IpVersion.ipv6, true),
        throwsArgumentError,
      );
    });

    test('an IPv6 literal with IpVersion.ipv4 throws ArgumentError', () {
      expect(
        () => DartPingIOS('::1', 1, 1, 2, 64, IpVersion.ipv4, true),
        throwsArgumentError,
      );
    });

    test('a matching literal and a hostname construct normally', () {
      expect(
        () => DartPingIOS('::1', 1, 1, 2, 64, IpVersion.ipv6, true),
        returnsNormally,
      );
      expect(
        () => DartPingIOS('example.com', 1, 1, 2, 64, IpVersion.ipv6, true),
        returnsNormally,
      );
    });
  });

  test('parser getter and setter are unsupported on iOS', () {
    final ping = DartPingIOS('host', 1, 1, 2, 64, IpVersion.ipv4, true);
    final dummyParser = PingParser(
      responseRgx: RegExp(''),
      summaryRgx: RegExp(''),
      timeoutRgx: RegExp(''),
      timeToLiveRgx: RegExp(''),
      unknownHostStr: RegExp(''),
    );
    expect(() => ping.parser, throwsUnimplementedError);
    expect(() => ping.parser = dummyParser, throwsUnimplementedError);
  });

  test('register() installs an iOS factory that builds a DartPingIOS', () {
    addTearDown(() => Ping.iosFactory = null);
    expect(Ping.iosFactory, isNull);

    DartPingIOS.register();

    expect(Ping.iosFactory, isNotNull);
    final built =
        Ping.iosFactory!('host', 1, 1, 2, 64, IpVersion.ipv4, null, utf8, true);
    expect(built, isA<DartPingIOS>());
  });

  test('listening starts the native run with the configured arguments',
      () async {
    final ping = DartPingIOS('example.com', 3, 1, 5, 64, IpVersion.ipv6, true);
    final sub = ping.stream.listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();

    final start = callNamed('start');
    final args = Map<String, dynamic>.from(start.arguments as Map);
    expect(args['host'], 'example.com');
    expect(args['count'], 3);
    expect(args['interval'], 1);
    expect(args['timeout'], 5);
    expect(args['ttl'], 64);
    expect(args['ipVersion'], 'ipv6');
    expect(args['id'], isNotNull);
  });

  test('forwards mapped events and closes after the terminal summary',
      () async {
    final ping = DartPingIOS('host', 2, 1, 2, 64, IpVersion.ipv4, true);
    final received = <PingEvent>[];
    final done = Completer<void>();
    ping.stream.listen(received.add, onDone: done.complete);
    await pumpEventQueue();

    final id = (callNamed('start').arguments as Map)['id'] as String;

    emitNativeEvent({
      'id': id,
      'type': 'response',
      'seq': 1,
      'ttl': 64,
      'time': 10,
      'ip': '1.1.1.1',
    });
    emitNativeEvent({
      'id': id,
      'type': 'summary',
      'transmitted': 2,
      'received': 2,
      'time': 2000,
    });

    await done.future;
    expect(received, hasLength(2));
    expect((received.first as PingResponse).seq, 1);
    expect((received.last as PingSummary).transmitted, 2);
  });

  test('ignores events addressed to a different run id', () async {
    final ping = DartPingIOS('host', 1, 1, 2, 64, IpVersion.ipv4, true);
    final received = <PingEvent>[];
    ping.stream.listen(received.add);
    await pumpEventQueue();

    final id = (callNamed('start').arguments as Map)['id'] as String;

    // Wrong id: must be dropped.
    emitNativeEvent({'id': 'someone-elses-run', 'type': 'response', 'seq': 9});
    await pumpEventQueue();
    expect(received, isEmpty);

    // Right id: delivered.
    emitNativeEvent({'id': id, 'type': 'response', 'seq': 1});
    await pumpEventQueue();
    expect(received, hasLength(1));
    expect((received.single as PingResponse).seq, 1);
  });

  test('stop() invokes the native stop and resolves to true', () async {
    final ping = DartPingIOS('host', null, 1, 2, 64, IpVersion.ipv4, true);
    final sub = ping.stream.listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();

    final result = await ping.stop();
    expect(result, isTrue);
    expect(callNamed('stop'), isNotNull);
  });

  test('cancelling the subscription stops the native run', () async {
    final ping = DartPingIOS('host', null, 1, 2, 64, IpVersion.ipv4, true);
    final sub = ping.stream.listen((_) {});
    await pumpEventQueue();
    expect(methodCalls.where((c) => c.method == 'stop'), isEmpty);

    await sub.cancel();
    await pumpEventQueue();

    // onCancel both tears down the event subscription and tells native to
    // stop so an unbounded run does not leak its socket/timer.
    expect(callNamed('stop'), isNotNull);
  });
}
