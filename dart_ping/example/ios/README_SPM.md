# SPM build mode — iOS example (no CocoaPods)

This example app uses **Flutter's Swift Package Manager (SPM) build mode**.
There is **no `Podfile` and no CocoaPods** in `example/ios/`: iOS support is
built directly into `dart_ping`, whose native ICMP engine is compiled by a
Dart build hook into a `dart:ffi` code asset — no Flutter plugin, no second
package, no `register()`. The Xcode project contains no `[CP]` CocoaPods
build phases and no `Pods` references. This is the primary acceptance surface
for the consolidation (see `SPEC.md` §spec:single-package-ios,
§spec:dart-ping-ios-retired; originally issue #73 §spec:spm-distribution).

The deterministic Swift ICMP framing/parse tests run in the `RunnerTests`
target, which compiles `../../native/ICMPPacket.swift` (the consolidated
engine's framing code) directly — there is no plugin module to import.

## Run the live acceptance test (macOS only)

The iOS build/run is a **macOS-only** operation (requires Xcode + the iOS
SDK) and **cannot be executed on a Linux CI host**.

1. Enable SPM for Flutter (once per machine):

   ```sh
   flutter config --enable-swift-package-manager
   ```

2. Run the example on an iOS simulator or device:

   ```sh
   cd dart_ping/example
   flutter run
   ```

3. In the running app, press the **ping** button. The host defaults to
   `google.com`. Confirm that:
   - per-probe **`PingResponse`** rows render as each probe returns, and
   - a final **`PingSummary`** row renders at the end of the run.

4. Confirm the app needs **no special entitlements** and no extra App
   Store review steps — it ships unchanged from a packaging standpoint.
   This validates `SPEC.md` §spec:no-special-entitlements (the engine's
   unprivileged `SOCK_DGRAM` ICMP design needs no entitlement, capability,
   or privileged execution, and does not trigger iOS's Local Network
   privacy prompt).
