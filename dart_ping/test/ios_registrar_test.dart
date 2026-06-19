import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping/dart_ping_ios_ffi.dart';
import 'package:dart_ping/src/ping/ios/ios_ping.dart';
import 'package:test/test.dart';

// Network-free tests for the opt-in iOS registrar.
//
// `registerDartPingIosFfi()` installs `IosPing.fromFactory` on the global
// `Ping.iosFactory` seam. We exercise ONLY what is reachable without the
// native code asset: that the seam becomes non-null and that invoking the
// installed factory constructs an `IosPing` (the constructor validates the
// address family only — it does NOT open the native asset). We never touch
// `.stream`/listen or any FFI function.
void main() {
  group('registerDartPingIosFfi', () {
    // `Ping.iosFactory` is global mutable static state; save and restore it so
    // this test does not leak into others.
    late Ping Function(
      String,
      int?,
      int,
      int,
      int,
      IpVersion,
      PingParser?,
      Encoding,
      bool,
    )? savedFactory;

    setUp(() {
      savedFactory = Ping.iosFactory;
      Ping.iosFactory = null;
    });

    tearDown(() {
      Ping.iosFactory = savedFactory;
    });

    test('installs a non-null factory on Ping.iosFactory', () {
      expect(Ping.iosFactory, isNull);
      registerDartPingIosFfi();
      expect(Ping.iosFactory, isNotNull);
    });

    test('the installed factory returns an IosPing for valid args', () {
      registerDartPingIosFfi();

      final ping = Ping.iosFactory!(
        '1.2.3.4',
        1,
        1,
        2,
        255,
        IpVersion.ipv4,
        null,
        const Utf8Codec(),
        true,
      );

      expect(ping, isA<IosPing>());
    });

    test('the installed factory ignores parser and encoding', () {
      registerDartPingIosFfi();

      // Pass a non-null parser and a non-default encoding: the native engine
      // emits typed events directly, so both are dropped and construction
      // still yields an IosPing.
      final ping = Ping.iosFactory!(
        '1.2.3.4',
        3,
        2,
        5,
        64,
        IpVersion.ipv4,
        PingParser(
          responseRgx: RegExp(''),
          summaryRgx: RegExp(''),
          timeoutRgx: RegExp(''),
          timeToLiveRgx: RegExp(''),
          unknownHostStr: RegExp(''),
        ),
        latin1,
        false,
      );

      expect(ping, isA<IosPing>());
    });
  });
}
