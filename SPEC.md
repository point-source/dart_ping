# Specification

Solution-space design for issue #73 — native, Swift Package Manager
(SPM)-compatible iOS support for `dart_ping`.

The problem (from §req:problem-statement): Flutter app developers who
have enabled Flutter's SPM build mode cannot consume `dart_ping_ios`.
The package ships no native iOS code of its own — it is a thin Dart
wrapper around the third-party `flutter_icmp_ping` plugin, which
distributes only a CocoaPods podspec. On an SPM-only project (no
`Podfile`) there is no path to add iOS ping support, and the maintainer
cannot fix it upstream because the native code lives in a dependency
they do not control. Separately, the iOS path has drifted from the other
platforms: `ttl` is ignored, `timeToLiveExceeded` and `noReply` never
surface, and the run summary omits the per-run error list.

The design replaces `flutter_icmp_ping` with a native Swift ICMP
implementation owned by this repository, shipped as a federated plugin
with SPM support. This both unblocks SPM and gives the maintainer the
control needed to close the parity gaps.

The public Dart API is unchanged. `dart_ping` remains the app-facing
package; `dart_ping_ios` remains the iOS implementation registered
through `Ping.iosFactory` (§spec:public-api-stability). The sections
below describe the iOS implementation only — `dart_ping`'s
android/linux/macos/windows subprocess paths are unaffected.

## Native Swift ICMP ping engine §spec:swift-icmp-engine
*Status: implemented (Batch 1) — Swift `PingEngine`/`ICMPPacket` landed over an unprivileged `SOCK_DGRAM` ICMP socket; pending macOS/on-device build verification (not compilable on the Linux CI host).*

The native iOS ping logic lives in this repository as Swift. The engine
opens an unprivileged ICMP datagram socket (`SOCK_DGRAM` /
`IPPROTO_ICMP`), resolves the target host, and sends ICMP Echo Request
probes on the schedule the caller requested (host, count, interval,
timeout). For each Echo Reply it matches the reply to its request by
sequence number, computes the round-trip time, and reports the
responding source IP and the reply's TTL. The engine has no dependency
on `flutter_icmp_ping` or any other CocoaPods-only package
(§req:constraints).

- When a target host responds, the engine shall report the probe's
  sequence number, the measured round-trip time, the reply TTL, and the
  responding source IP.
- The engine shall send no more than `count` probes (or run until
  stopped when `count` is unset), spacing probes by `interval` and
  marking a probe lost when no reply arrives within `timeout`.
- The engine shall require no special iOS entitlements and no privileged
  (root) execution (see §spec:no-special-entitlements).

Observable behavior surfaces through the Dart stream
(§spec:ios-ping-behavior); this section owns the native engine's
contract, not the channel wiring.

**Why a self-owned Swift engine:** the maintainer cannot close parity
gaps or guarantee SPM distribution while the native code lives in a
third-party CocoaPods package (§req:problem-statement). Owning the
engine is the enabling decision for every other iOS section.

**Why `SOCK_DGRAM` ICMP rather than a raw socket:** macOS/iOS permit
unprivileged ICMP echo over `SOCK_DGRAM` (the mechanism Apple's own
`SimplePing` sample uses), so no entitlement, no root, and no extra App
Store review are needed (§req:quality-attributes — security/permissions;
§req:success-criteria). A `SOCK_RAW` implementation was rejected: it
requires elevated privileges unavailable to a sandboxed iOS app.

**Tradeoff:** the engine reimplements ICMP framing, sequence matching,
and timing that `flutter_icmp_ping` previously provided. This is
accepted as the cost of ownership and is the prerequisite for parity and
SPM. Round-trip timing is expected to stay comparable to the prior
implementation (§req:quality-attributes — accuracy).

## SPM distribution of dart_ping_ios §spec:spm-distribution
*Status: implemented (Batch 1) — federated iOS plugin (`pluginClass`, no podspec), `Package.swift` (iOS 13.0 + `FlutterFramework`), `dart_ping_ios` bumped to 5.0.0, `flutter_icmp_ping` removed, and the example regenerated Podfile-free; pending macOS simulator/device acceptance run.*

`dart_ping_ios` is a federated Flutter plugin that declares its iOS
implementation as a Swift Package, buildable under Flutter's Swift
Package Manager build mode. The package ships no podspec and no
CocoaPods dependency.

- A Flutter app with SPM enabled and **no `Podfile` present** shall be
  able to add `dart_ping_ios`, build for iOS, and run network pings
  producing correct per-probe responses and a run summary
  (§req:success-criteria — must-have).
- The bundled example app shall run on an iOS simulator or device with
  SPM enabled and no `Podfile`, with ping working end-to-end
  (§req:success-criteria — primary acceptance test).
- The package shall ship as a **new major version** of `dart_ping_ios`,
  SPM-only (§req:constraints, §req:priorities).
- The minimum supported iOS version shall be **iOS 13.0**.

**Why iOS 13.0:** it matches Flutter's current minimum-deployment baseline,
so the package imposes no floor stricter than Flutter already requires,
while the `SOCK_DGRAM` ICMP API is available well below it. A higher floor
was rejected as gratuitously exclusionary; a lower floor buys nothing
because Flutter itself will not target it. (This was originally specified
as iOS 12.0; during `/plan`-driven implementation the baseline was found to
be 13.0 on the target Flutter toolchain — the Swift Package Manager
`FlutterFramework` package that plugins depend on targets `.iOS("13.0")`,
so declaring 12.0 would fail SwiftPM resolution. The value was corrected to
13.0 to preserve the stated intent: track Flutter's baseline exactly.)

**Why SPM-only (drop CocoaPods) rather than dual-publish:** Flutter is
moving toward SPM as the default iOS/macOS build system and CocoaPods is
on a deprecation path (§req:problem-statement). Maintaining both a
podspec and a Swift Package for the rewrite doubles the native build
surface for a path the ecosystem is leaving. Existing CocoaPods
consumers are served instead by the prior release
(§spec:cocoapods-continuity), so dropping CocoaPods here is not a
regression for them.

**Scope boundary:** iOS only (§req:constraints). macOS continues to be
served natively by the core `dart_ping` subprocess path and is out of
scope.

## iOS ping responses and summary §spec:ios-ping-behavior
*Status: implemented (Batch 1) — native results map onto unchanged `PingResponse`/`PingSummary`; per-probe responses and the completion summary flow over the method/event channel; `stop()` lets the summary emit before the stream closes. Mapping covered by unit tests. (Full error set and the per-run `errors` list landed in Batch 2 — see §spec:ios-error-parity.)*

On iOS, listening to a `Ping` instance's `stream` produces the same
`PingData` event shape as every other platform. The native engine
(§spec:swift-icmp-engine) feeds results to the Dart layer, which maps
them onto the unchanged models.

- For each Echo Reply, the system shall emit a `PingData` whose
  `response` is a `PingResponse` carrying `seq`, `ttl`, `time`
  (round-trip), and `ip`.
- When the run completes, the system shall emit a `PingData` whose
  `summary` is a `PingSummary` carrying `transmitted`, `received`,
  `time`, and the per-run `errors` list (§spec:ios-error-parity).
- `stop()` shall halt the run and still allow the summary event to be
  emitted before the stream closes, matching the documented contract of
  the `Ping` interface.

**Why map onto the existing models rather than expose iOS-specific
types:** the public API is fixed (§req:constraints,
§spec:public-api-stability); shared cross-platform app code must handle
iOS responses identically to Android/Linux/macOS/Windows
(§req:user-stories).

**Tradeoff:** the native↔Dart boundary (a Flutter method/event channel)
is an implementation detail deliberately left unspecified here so the
spec survives a change of transport mechanism; only the observable
`PingData` contract is normative.

## iOS TTL control and time-to-live-exceeded §spec:ios-ttl
*Status: implemented (Batch 2) — the Swift engine sets the outgoing IP hop limit via `setsockopt(IP_TTL)` to the caller's `ttl`, and the receive path parses ICMP Time Exceeded (type 11) to recover the original probe's sequence and the intermediate-hop IP, surfacing a `timeToLiveExceeded` event (response carrying hop `ip`+`seq`, plus the error) instead of dropping it. Dart-side mapping covered by unit tests. Pending on-device/simulator verification (not compilable on the Linux CI host); note the platform risk that Darwin may deliver Time Exceeded only via the socket error queue (`MSG_ERRQUEUE`) rather than the normal `recvmsg` path used here.*

The system honors the `ttl` parameter on iOS and reports hop-limit
expiry the same way the other platforms do.

- The system shall set the outgoing probes' IP hop limit to the caller's
  `ttl` value (§req:success-criteria, §req:user-stories).
- When an intermediate hop returns an ICMP Time Exceeded message for a
  probe, the system shall emit a `timeToLiveExceeded` event/error rather
  than silently dropping it.

**Why this matters:** the previous iOS path ignored `ttl` entirely and
never surfaced TTL-exceeded events, so iOS could not support
traceroute-style diagnostics that Android (fixed in #49), Linux, macOS,
and Windows already support (§req:user-stories,
§req:quality-attributes — parity). This is a high-priority parity gap,
secondary only to "SPM works at all" (§req:priorities).

## iOS error parity §spec:ios-error-parity
*Status: implemented (Batch 2) — the engine accumulates every error during a run and emits the full set — `timeToLiveExceeded`, `requestTimedOut`, `unknownHost`, `noReply`, `unknown` — over the channel, where `noReply` is a run-level error (received == 0 with probes sent, matching the Linux/macOS exit-code-1 semantics). The summary payload now carries an `errors` list, so `PingSummary.errors` is populated on iOS exactly as on the other platforms. Mapping (including the combined response+error for timeouts/TTL-exceeded and the summary error-list) covered by unit tests. Pending on-device confirmation of the live error conditions.*

The system surfaces the full cross-platform error set on iOS and records
it in the run summary.

- The system shall report each of `timeToLiveExceeded`,
  `requestTimedOut`, `unknownHost`, `noReply`, and `unknown` on iOS
  under the conditions the other platforms report them
  (§req:success-criteria).
- The system shall include every error that occurred during a run in
  `PingSummary.errors`, so the summary's error list matches the other
  platforms (§req:success-criteria, §req:user-stories).

**Why:** the prior iOS wrapper mapped only `requestTimedOut`,
`unknownHost`, and a catch-all `unknown`, and never populated
`PingSummary.errors`. Cross-platform code that branches on `ErrorType`
therefore behaved differently on iOS (§req:quality-attributes — parity).
The `ErrorType` enum and `PingSummary.errors` already exist in the
public API, so this section closes the iOS-side gap without an API
change. High priority (§req:priorities).

## Unchanged public Dart API §spec:public-api-stability
*Status: implemented (Batch 1) — `Ping`/`PingData`/`PingResponse`/`PingSummary`/`PingError` unchanged; `DartPingIOS.register()` still installs `Ping.iosFactory` with the same factory signature. The rewrite is confined to `dart_ping_ios` internals; existing app code compiles unchanged.*

The public Dart API is unchanged by this work. The `Ping` interface and
the `PingData` / `PingResponse` / `PingSummary` / `PingError` (and
`ErrorType`) shapes keep their current form, and iOS support is still
enabled by calling `DartPingIOS.register()`, which installs the iOS
factory on `Ping.iosFactory`.

- Existing app code that constructs `Ping(...)` and listens to `stream`
  shall compile and run on the new version without edits
  (§req:constraints).
- `DartPingIOS.register()` shall remain the documented entry point for
  enabling iOS support.

**Why hold the API fixed:** the rewrite is native/distribution-level;
forcing app-code changes would compound an already-breaking
(SPM-only) major release (§spec:spm-distribution) for no user benefit
(§req:user-stories). The break is confined to the build system, not the
Dart surface.

## CocoaPods consumers preserved §spec:cocoapods-continuity
*Status: not started*

Projects that have not migrated to SPM keep a working iOS path on the
previous, `flutter_icmp_ping`-backed release of `dart_ping_ios`.

- The previous `dart_ping_ios` release shall remain published and
  resolvable, so CocoaPods-based projects that pin to it continue to
  build and ping (§req:success-criteria).
- Because the rewrite ships as a new major version
  (§spec:spm-distribution), existing version constraints shall not pull
  the SPM-only rewrite into a CocoaPods project automatically
  (§req:constraints).

**Why a clean major-version split rather than a compatibility shim:**
the two implementations have incompatible native distribution models
(podspec vs. Swift Package). A new major version lets migration happen
on each consumer's schedule instead of as a forced break
(§req:user-stories), which is cheaper and lower-risk than maintaining a
dual-distribution shim in one release.

## No special entitlements or App Store review steps §spec:no-special-entitlements
*Status: satisfied by design (Batch 1) — the engine uses an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket (no raw socket, no root, no entitlement); the example ships with no added entitlements. Pending macOS confirmation that no Local Network prompt or entitlement is required at runtime.*

Using iOS ping shall not require the consuming app to add special
entitlements or take extra App Store review steps
(§req:success-criteria, §req:quality-attributes — security/permissions).

This is satisfied by the engine's `SOCK_DGRAM` ICMP design
(§spec:swift-icmp-engine): unprivileged ICMP echo needs no entitlement,
no special capability, and no privileged execution, so a consuming app
ships unchanged from an App Store packaging standpoint.

**Why call this out as its own section:** the original requirement
flagged it as soft and "to confirm during /plan." The decision is to
confirm it as a hard constraint and let it drive the socket choice — if
a future change to the engine were to require an entitlement, this
section would fail, which is the signal we want. Local-network ping does
not trigger iOS's Local Network privacy prompt, which applies to LAN
discovery APIs, not ICMP to a routable host; this is noted so a reviewer
does not mistake its absence for a defect.

## iOS behavior tests §spec:ios-tests
*Status: not started*

Automated tests cover the iOS ping behavior where feasible
(§req:success-criteria, §req:quality-attributes — testability).

- The Dart-side mapping from native results to `PingData` /
  `PingResponse` / `PingSummary` / `PingError` shall be covered by unit
  tests, including the error-parity mapping (§spec:ios-error-parity) and
  summary error-list population.
- Swift-side ICMP framing/parsing logic shall be covered by unit tests
  where it can be exercised without a live network.
- The example app remains the manual end-to-end acceptance path on a
  simulator or device (§spec:spm-distribution).

**Why "where feasible" rather than full coverage:** live ICMP behavior
depends on network conditions and intermediate routers that cannot be
reproduced deterministically in CI. The testable seam is the
result-mapping logic on both sides of the channel; the live round trip
stays a manual acceptance test via the example app. Nice-to-have
priority (§req:priorities) — it does not gate the must-have SPM bar.
