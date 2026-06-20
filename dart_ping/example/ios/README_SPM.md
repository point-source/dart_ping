# SPM build mode — iOS example (no CocoaPods)

This example app uses **Flutter's Swift Package Manager (SPM) build mode**.
There is **no `Podfile` and no CocoaPods** in `example/ios/`: the iOS plugin
implementation (`dart_ping_ios`) is consumed as a Swift Package, and the
Xcode project contains no `[CP]` CocoaPods build phases and no `Pods`
references. This is the primary acceptance surface for issue #73
(see `SPEC.md` §spec:spm-distribution).

## Run the live acceptance test (macOS only)

The iOS build/run is a **macOS-only** operation (requires Xcode + the iOS
SDK) and **cannot be executed on a Linux CI host**.

1. Enable SPM for Flutter (once per machine):

   ```sh
   flutter config --enable-swift-package-manager
   ```

2. Run the example on an iOS simulator or device:

   ```sh
   cd dart_ping_ios/example
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
