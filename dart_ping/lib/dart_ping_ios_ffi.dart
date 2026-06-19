/// Opt-in registration for the FFI-backed iOS ping engine.
///
/// During the package consolidation transition (#28-2), iOS support lives in
/// `dart_ping` and is installed via the existing `Ping.iosFactory` seam.
/// A Flutter iOS app calls [registerDartPingIosFfi] once at start-up; then
/// `Ping(host, ...)` returns the FFI-backed iOS implementation. The seam and
/// this registration call are removed in #28-3 (§spec:ios-auto-wiring), where
/// the `Ping` factory dispatches to iOS internally.
library;

import 'package:dart_ping/src/ping/ios/ios_ping.dart';
import 'package:dart_ping/src/ping_interface.dart';

/// Installs the FFI-backed iOS [Ping] implementation on [Ping.iosFactory].
void registerDartPingIosFfi() {
  Ping.iosFactory = IosPing.fromFactory;
}
