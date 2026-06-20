// Network-free drift guard for the iOS `dart:ffi` bindings
// (§spec:ios-ffi-binding). Asserts the mirrored enum integer constants match
// the values in `native/include/dart_ping_ffi.h`, and that the struct lays out
// to a non-zero size.
//
// This test does NOT call any native function: the `dart_ping_ffi` code asset
// is linked only at iOS app-build time, so calling [dartPingStart] /
// [dartPingStop] / [dartPingFreeEvent] here would fail to link. Inspecting the
// struct/constants is purely a compile-time/layout check and is safe on Linux.

import 'dart:ffi';

import 'package:dart_ping/src/ping/ios/dart_ping_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('iOS FFI binding constants mirror dart_ping_ffi.h', () {
    test('dart_ping_event_kind values', () {
      expect(DartPingEventKind.response, 0);
      expect(DartPingEventKind.error, 1);
      expect(DartPingEventKind.summary, 2);
    });

    test('dart_ping_error_kind values', () {
      expect(DartPingErrorKind.requestTimedOut, 0);
      expect(DartPingErrorKind.timeToLiveExceeded, 1);
      expect(DartPingErrorKind.noReply, 2);
      expect(DartPingErrorKind.unknownHost, 3);
      expect(DartPingErrorKind.noRoute, 4);
      expect(DartPingErrorKind.unknown, 5);
    });

    test('dart_ping_family values', () {
      expect(DartPingFamily.v4, 0);
      expect(DartPingFamily.v6, 1);
    });
  });

  test('DartPingEvent struct has a non-zero size', () {
    expect(sizeOf<DartPingEvent>(), greaterThan(0));
  });
}
