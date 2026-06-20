import 'dart:async';

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

  test('register() is a deprecated no-op (iOS now auto-wires in dart_ping)', () {
    // The package is discontinued; iOS auto-wires inside dart_ping's factory,
    // so register() does nothing and must not throw.
    // ignore: deprecated_member_use_from_same_package
    expect(DartPingIOS.register, returnsNormally);
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
    // The 8th positional arg (nat64Synthesis) is true here, proving the
    // default-on option threads onto the native `start` arguments
    // (§spec:nat64-tests).
    expect(args['nat64Synthesis'], true);
    expect(args['id'], isNotNull);
  });

  test('disabling nat64Synthesis threads the raw-path signal to native start',
      () async {
    // With the nat64Synthesis positional set to false, the bridge must forward
    // `nat64Synthesis: false` so the native engine takes the raw, family-pinned
    // path with no IPv6 synthesis (§spec:nat64-tests).
    final ping = DartPingIOS('example.com', 3, 1, 5, 64, IpVersion.ipv6, false);
    final sub = ping.stream.listen((_) {});
    addTearDown(sub.cancel);
    await pumpEventQueue();

    final start = callNamed('start');
    final args = Map<String, dynamic>.from(start.arguments as Map);
    expect(args['nat64Synthesis'], false);
  });

  test(
      'the on/off nat64Synthesis flag threads to native start for an '
      'IPv4-literal + ipv4 call', () async {
    // Scope of THIS test: the Dart bridge forwards the flag verbatim for the
    // IPv4-literal + IpVersion.ipv4 argument shape (both on and off), so the
    // native engine receives the choice it needs. It does NOT — and cannot —
    // exercise the synthesis DECISION itself: the bridge passes the flag through
    // unchanged regardless of host/family, so this would still pass if the engine
    // ignored it. The actual un-pin-vs-pin decision and the routable-address
    // selection are covered offline on the native side by RunnerTests
    // (`shouldSynthesize`, `synthesizedTransport`) (§spec:nat64-tests).
    Future<bool> threadedFlagFor(bool nat64) async {
      methodCalls = [];
      final ping = DartPingIOS('13.35.27.1', 1, 1, 2, 64, IpVersion.ipv4, nat64);
      final sub = ping.stream.listen((_) {});
      addTearDown(sub.cancel);
      await pumpEventQueue();
      final args = Map<String, dynamic>.from(callNamed('start').arguments as Map);
      return args['nat64Synthesis'] as bool;
    }

    // ON -> the engine is told it may synthesize a NAT64 path for the literal.
    expect(await threadedFlagFor(true), isTrue);
    // OFF -> the engine is told to take the raw, family-pinned path (no synthesis).
    expect(await threadedFlagFor(false), isFalse);
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
