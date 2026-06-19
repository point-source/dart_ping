# Specification

This document covers the following areas, matching REQUIREMENTS.md:

- **iOS SPM migration (#73)** — `§spec:swift-icmp-engine` …
  `§spec:ios-tests` below (implemented).
- **Maintenance & modernization refresh** — the `§spec:dependency-currency`
  … `§spec:code-audit` sections (complete).
- **`base_ping` stream lifecycle robustness (#76)** —
  `§spec:stream-lifecycle-robustness` (implemented). A focused
  follow-up to two hang paths deferred from `§spec:code-audit`.
- **Continuous integration & coverage expansion (#74, #77)** — the
  `§spec:ci` … `§spec:coverage-expansion` sections (implemented). This is
  new work *beyond* the refresh's "fill gaps only" scope, which had
  deliberately excluded CI (§spec:test-coverage).
- **IPv6 / address-family error clarity (#69)** — the
  `§spec:ipv6-address-family-selector` …
  `§spec:address-family-error-tests` sections (implemented). A
  correctness-of-errors fix so address-family and routing failures stop
  masquerading as "Unknown Host" on IPv6-enabled networks.
- **Interface selection (#72)** — `§spec:interface-selection` …
  `§spec:interface-listing` at the very end (not started). An optional way
  to pin pings to a chosen network interface or source address on the
  subprocess platforms, with a helper to enumerate the host's interfaces.
  Additive on top of the existing `Ping` API.
- **Concurrent-ping isolation (#70)** — `§spec:concurrent-isolation`
  at the very end (implemented). A reported cross-contamination defect
  between simultaneously-running `Ping` instances.
- **Summary statistics (#63)** — the `§spec:stats-event-model` …
  `§spec:stats-tests` sections at the very end (not started). Surfaces
  round-trip min / avg / max / stddev, jitter, and packet-loss — in the run
  summary and live during a run, with iOS parity — via a from-scratch
  redesign of the stream's event/data classes, folded into the unreleased
  breaking `dart_ping` 10.0.0 / `dart_ping_ios` 6.0.0 majors. **Supersedes
  the API-stability promises of the preceding areas.**
- **Package consolidation — one `dart_ping` with FFI-backed iOS (#28, #48)** —
  the `§spec:single-package-ios` … `§spec:dart-ping-ios-retired` sections at
  the very end (not started). Collapses `dart_ping_ios` into a single
  pure-Dart `dart_ping` that carries the native iOS engine as a build-hook
  **code asset** and drives it over `dart:ffi`, replacing the Flutter
  platform channels. This removes the second package and the `register()`
  step (#28) and fixes iOS ping inside background isolates (#48), while the
  pure-Dart-with-no-Flutter-SDK promise is preserved as a hard gate. Folds
  into the same unreleased `dart_ping` 10.0.0 train; `dart_ping_ios` is
  discontinued. Reuses the native iOS SPM engine (§spec:swift-icmp-engine)
  and preserves its observable behavior (§spec:ios-ping-behavior,
  §spec:ios-error-parity, §spec:ios-ttl, §spec:stats-ios) while replacing the
  binding mechanism and the package boundary of §spec:spm-distribution.

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
*Status: implemented (Batch 3) — README and CHANGELOG document the clean major-version split: 5.0.0 ships SPM-only while the prior `flutter_icmp_ping`-backed 4.x line stays published/resolvable, and the major bump keeps existing `^4.x` constraints from auto-pulling the rewrite into CocoaPods projects. Continuity of the 4.x release on pub.dev is inherent (prior versions remain published) and is not re-verified here.*

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
*Status: satisfied by design (Batch 1) — the engine uses an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket (no raw socket, no root, no entitlement); the example ships with no added entitlements. Documented for consumers in the README migration guide (Batch 3): no special entitlements / extra App Store review steps, and local-network ping does not trigger the iOS Local Network privacy prompt. Pending macOS confirmation that no Local Network prompt or entitlement is required at runtime.*

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
*Status: implemented (Batch 3) — Dart-side mapping is covered by `dart_ping_ios/test/ping_event_mapper_test.dart` (19 cases over the native-result → PingData/PingResponse/PingSummary/PingError seam, including the full ErrorType set, the combined response+error contract, and PingSummary.errors population); runs green under `flutter test` on the Linux CI host. Swift-side ICMP framing/sequence/parse logic is covered by network-free XCTest cases in the example's `RunnerTests` target (`ICMPPacket` widened to `public`); hand-verified but not compiled here — run on macOS via `xcodebuild test -workspace Runner.xcworkspace -scheme Runner`. Live ICMP round-trips remain a manual example-app acceptance path by design.*

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

---

# Maintenance & modernization refresh

Solution-space design for the cross-package health pass defined in
REQUIREMENTS.md (`§req:refresh-*`). The sections below are independent of
the #73 SPM work above; they describe the desired end state of the
repository's dependencies, SDK floor, lint baseline, parser correctness,
test suite, documentation, and a one-time security/quality audit.

The driver (from §req:refresh-problem-statement) is accumulated drift:
dev-dependencies sit at old majors (`lints` 2 vs 6, `flutter_lints` 2 vs
6), the SDK floor (`>=3.0.0`) predates current tooling, the root README
describes an iOS implementation that no longer exists, the parser crashes
on macOS/Windows TTL-exceeded lines, and the new native Swift engine has
never had a focused review.

## Dependency currency §spec:dependency-currency
*Status: complete*

Both packages resolve their direct dependencies at the latest versions
the constraint solver allows, including major upgrades that require code
changes.

- `dart pub get` (core) and `flutter pub get` (iOS) shall resolve cleanly
  with every **direct** dependency constraint admitting its latest
  published major: `lints` 6.x and `test` 1.31.x in `dart_ping`;
  `flutter_lints` 6.x and `test` 1.31.x in `dart_ping_ios`. The
  `async`/`collection` runtime constraints already admit their latest and
  stay as-is unless a tighter floor is needed (§req:refresh-success-criteria).
- `dart pub outdated` shall report no direct dependency behind its latest
  resolvable version (§req:refresh-success-criteria, §req:refresh-constraints).
- No **direct** dependency shall be a discontinued package. (`js` appears
  only transitively via the test toolchain and is out of this package's
  control; it is noted, not owned here.)

**Why move to latest majors rather than minimal bumps:** the packages are
libraries other apps resolve against; leaving dev-tooling majors behind
drags superseded analyzer/test machinery into every consumer's resolution
and blocks adoption of current lint rules. The major bumps that force code
changes (lints 6) are in scope by decision (§req:refresh-constraints).

## Dart SDK floor §spec:sdk-floor
*Status: complete*

Both packages declare `environment: sdk: ">=3.8.0 <4.0.0"`.

- The lower bound shall be the lowest stable Dart that the adopted tooling
  requires — **3.8.0**, the floor declared by `lints` 6 and `flutter_lints`
  6 (both `sdk: ^3.8.0`) — and no higher (§req:refresh-success-criteria,
  §req:refresh-quality-attributes — compatibility).
- The floor shall not be raised to match the installed toolchain (Dart
  3.12) absent a concrete feature that requires it; no such feature is
  adopted in this pass, so 3.8.0 stands (§req:refresh-constraints).

**Why 3.8.0 and not higher:** the only concrete driver is the lint
toolchain, which floors at 3.8.0. Raising further would exclude consumers
for no delivered benefit, violating the "don't break what doesn't buy us
anything" constraint (§req:refresh-priorities). 

**Tradeoff (minor bump, not breaking):** raising the floor from 3.0.0 to
3.8.0 shipped as a **minor** version bump (`dart_ping` 9.1.0,
`dart_ping_ios` 5.1.0), not a major. Pub's solver filters candidate
versions by SDK constraint, so a consumer on an older Dart keeps resolving
the prior release rather than failing — the bump is not a forced break.
The public API is unchanged and only dev-dependencies (`lints`/`test`)
took major bumps, neither of which reaches consumers. Adopting current
lints (a stated must-have) is impossible on the old floor, so the bump
buys a concrete benefit (§req:refresh-constraints, §req:refresh-priorities).

## Lint baseline §spec:lint-baseline
*Status: complete*

The code satisfies the current lint rule sets with no analyzer findings,
and the analysis configuration carries no dead settings.

- `dart analyze` in `dart_ping` and `flutter analyze` in `dart_ping_ios`
  shall each report **zero** issues under `lints` 6 / `flutter_lints` 6
  (§req:refresh-success-criteria).
- The `analysis_options.yaml` of both packages shall contain no
  `dart_code_metrics` block. That tooling is no longer part of the lints
  ecosystem and is inert dead config; it is removed (or, if metric
  enforcement is still wanted, replaced with a maintained equivalent —
  nice-to-have) (§req:refresh-quality-attributes — maintainability,
  §req:refresh-priorities).

**Why zero issues rather than a tolerated baseline:** the packages are
small and the lint upgrade is the point of the SDK bump; a clean analyze
is the observable proof the upgrade landed. New rules that flag existing
code are fixed in place rather than suppressed wholesale, so the upgrade
delivers its intended signal.

## TTL-exceeded parse correctness §spec:ttl-exceeded-parse
*Status: complete*

On every platform, a TTL/hop-limit-exceeded line from the system `ping`
produces a `timeToLiveExceeded` `PingData` — never an exception.

- When the macOS or Windows parser receives a TTL-exceeded line (e.g.
  `"92 bytes from 172.17.0.1: Time to live exceeded"` /
  `"Reply from 10.20.60.1: TTL expired in transit."`), the system shall
  emit a `PingData` whose `error` is `ErrorType.timeToLiveExceeded`,
  carrying whatever fields the platform's pattern exposes (`ip` always;
  `seq` only when the pattern captures it) (§req:refresh-success-criteria).
- The TTL-exceeded parse path shall not assume a `seq` capture group
  exists; it reads `seq` only when the active pattern defines one, exactly
  as the timeout and successful-response paths already do.

**Why this is a correctness bug, not a missing feature:** the parser's
TTL-exceeded branch force-unwraps the `seq` named group, but only the
Linux pattern defines that group. On macOS and Windows the unwrap throws
`"Not a capture group name: seq"`, so a real hop-limit-exceeded reply
crashes the transform stream instead of surfacing the event the other
platforms surface. This breaks traceroute-style use on those platforms
and is the cause of the two known-failing `parse_test` cases
(§req:refresh-problem-statement). The fix aligns this branch with the
existing `groupNames.contains('seq')` guard used elsewhere in the parser,
restoring cross-platform parity (§req:refresh-success-criteria).

## Test suite integrity and coverage §spec:test-coverage
*Status: complete*

The full test suite passes for both packages with no known-failing or
skipped cases, and previously thin areas gain coverage.

- `dart test` (core) and `flutter test` (iOS) shall pass with **no**
  failing or `skip`-ped tests — including the macOS and Windows
  "TTL Exceeded" `parse_test` cases, which pass once
  §spec:ttl-exceeded-parse lands (§req:refresh-success-criteria).
- Thinly covered behavior shall gain tests where a deterministic seam
  exists: parser error/edge paths (`errorStrs` matches, malformed summary,
  the TTL-exceeded `seq`/no-`seq` split) and the stream start/stop
  lifecycle in `base_ping` (§req:refresh-success-criteria).
- No continuous-integration workflow or coverage-threshold gate is
  introduced in this pass; the goal is closing obvious gaps, not
  infrastructure (§req:refresh-constraints). *(CI and further coverage
  were later taken up as separate work — see §spec:ci and
  §spec:coverage-expansion.)*

**Why gap-filling without CI:** the constraint is explicit — fill gaps,
don't build infrastructure (§req:refresh-priorities). The highest-value
coverage is the parser, which is pure and deterministic (string in →
`PingData` out) and is exactly where the known bug lived, so a regression
test there is both cheap and load-bearing.

## Documentation accuracy §spec:doc-accuracy
*Status: complete*

The repository's documentation describes the system as it actually ships.

- The root `README` shall describe `dart_ping_ios` as it exists at 5.0.0 —
  a native Swift ICMP plugin distributed via Swift Package Manager — and
  shall not state that iOS support "adds cocoa dependencies" or relies on
  CocoaPods, which is false as of the #73 rewrite
  (§req:refresh-success-criteria, §req:refresh-problem-statement).
- Each package `README`, `CHANGELOG`, and the public dartdoc shall reflect
  current supported platforms, the SDK floor (§spec:sdk-floor), and the
  iOS distribution model, so a new reader can install and use each package
  from the docs without following a stale instruction
  (§req:refresh-user-stories).

**Why call documentation out as a spec section:** the root README predates
the native-Swift rewrite and actively misdirects iOS adopters toward a
CocoaPods story that no longer exists — a correctness defect in the
product's primary surface, not cosmetic polish. Accurate docs are a stated
success criterion (§req:refresh-success-criteria).

## Code audit and Swift hardening §spec:code-audit
*Status: complete*

The Dart code (both packages) and the native Swift ICMP engine have been
reviewed once for bugs, security flaws, and improvement opportunities, and
the findings are enumerated and triaged (fix-now / defer / won't-fix), with
cheap, clearly-correct fixes applied.

- The audit shall cover the Dart source of both packages and the Swift
  sources (`PingEngine`, `ICMPPacket`, `DartPingIosPlugin`), producing a
  written, triaged finding list (§req:refresh-success-criteria,
  §req:refresh-priorities).
- Security-relevant Swift paths that parse **untrusted inbound network
  data** shall be explicitly assessed for out-of-bounds reads and
  malformed-input handling: IPv4-header stripping, Echo Reply parsing, ICMP
  Time Exceeded original-sequence recovery, and the hand-rolled
  `cmsg` ancillary-data walk (§req:refresh-quality-attributes — security).
- No unaddressed **high-severity** finding shall remain at the end of the
  pass; lower-severity findings may be deferred but shall be recorded.

**Attack surface and why this section exists:** the engine binds a
`SOCK_DGRAM`/`IPPROTO_ICMP` socket and parses every ICMP datagram the
kernel delivers to it. Any host that can route a packet to the device can
send crafted or truncated ICMP messages; the parsing code (length-prefixed
IP header walk, fixed-offset field reads, manual `cmsg` pointer arithmetic)
operates on that attacker-influenced input. A bounds error there is reached
by hostile network input, with a blast radius of the consuming app's
process (read past a buffer → crash or info leak). This is new,
in-repo, never-audited code (§spec:swift-icmp-engine), so a focused review
of the parsing bounds is proportionate (§req:refresh-quality-attributes —
security). The Dart subprocess parsers, by contrast, consume the local
`ping` binary's output — lower trust concern, reviewed for correctness
rather than hostile input.

**Why a one-time audit rather than an ongoing gate:** the constraint
excludes new CI/infrastructure in this pass (§spec:test-coverage,
§req:refresh-constraints). The deliverable is the triaged finding list and
the applied cheap fixes; standing enforcement is out of scope.

---

# base_ping stream lifecycle robustness

Solution-space design for issue #76 (`§req:robustness-*`), a focused
follow-up to two medium-severity hang paths the maintenance audit surfaced
and deferred (`§spec:code-audit`). The work is confined to the core
`dart_ping` package and changes no public surface; it is independent of the
#73 iOS work and the rest of the refresh.

The problem (from §req:robustness-problem-statement): a consumer of the
`Ping` stream expects it to always finish — delivering responses and a
summary, or surfacing an error they can catch. On two edge paths the stream
instead stays open forever, with no error and no completion, so a consumer
awaiting it (`await for`, `.drain()`, `.last`, `stop()`) blocks
indefinitely. Both paths arise because a failure is raised from an async
context whose future nobody awaits — the `onDone` callback on an unmapped
non-zero exit, and the `onListen` body before the subscription is wired up —
so the exception is swallowed and the stream controller is never closed.

## Stream always terminates and surfaces errors §spec:stream-lifecycle-robustness
*Status: implemented (dart_ping 9.1.1) — teardown centralized through an idempotent `_closeController()` and a `try/finally` in `_cleanup`, so the `StreamController` closes exactly once on every terminal path. Launch failures (incl. a missing `ping` binary, which reports the binary could not be found) are caught in `_onListen` and routed to the error channel before closing; an unmapped non-zero exit surfaces `throwExit`'s exception via `addError` instead of swallowing/throwing in `onDone`. stderr/stdout are decoded and line-split independently before merging. Covered by network-free `dart test` cases in `dart_ping/test/stream_lifecycle_test.dart` (launch failure, unmapped exit, normal-completion regression guard, close-exactly-once across all paths) that fail on a hang or swallowed error; public API and normal-run output unchanged.*

The `Ping` stream terminates on every code path and routes failures through
its error channel rather than leaving the consumer to hang. Errors surface
through the stream's existing error channel, which consumers already handle;
no public type or method changes (§spec:public-api-stability,
§req:robustness-quality-attributes — compatibility).

- When the ping process fails to launch, the stream shall emit an error
  event and then close within bounded time, instead of hanging. When the
  failure is a missing `ping` binary, the error's message shall indicate
  that the ping binary could not be found
  (§req:robustness-success-criteria, §req:robustness-user-stories).
- When the process exits with a non-zero code that the platform does not
  map to a known `PingError`, the stream shall emit an error event and then
  close, instead of staying open forever
  (§req:robustness-success-criteria, §req:robustness-user-stories).
- On every path — normal zero-exit completion, a mapped error exit, an
  unmapped exit, a launch failure, and cancel/`stop()` — the stream shall
  close exactly once, so a consumer awaiting completion always returns and
  never deadlocks (§req:robustness-success-criteria,
  §req:robustness-quality-attributes — reliability).
- For a successful run (zero exit) or a recognized error exit, the consumer
  shall still receive the same per-probe responses, the run summary, and the
  per-run `PingSummary.errors` list as before, and the stream shall close as
  before (§req:robustness-success-criteria — regression guard).
- Each diagnostic line the consumer expects shall be delivered whole; the
  combination of the process's stderr and stdout shall not corrupt, split,
  or drop a line (§req:robustness-success-criteria,
  §req:robustness-quality-attributes — reliability).
- The missing-binary launch failure, the unmapped non-zero exit, and an
  unchanged normal completion shall each be covered by an automated test
  under `dart test` that runs without a live network and fails if the stream
  hangs or swallows the error (§req:robustness-success-criteria,
  §req:refresh-success-criteria — stream-lifecycle coverage).

**Why a hang is the failure to design out:** a hung stream is strictly worse
than an error — there is nothing to catch, nothing to await, and no timeout,
so the caller simply stalls (§req:robustness-problem-statement). The fix
reframes both edge paths as ordinary stream errors: a failure on any path
becomes an error event on the channel consumers already use, and the
controller is closed on every path so completion is guaranteed. The two
specific defects — a throw inside the `onDone` callback on an unmapped exit,
and a throw escaping the async start-up before the subscription exists — are
the mechanisms behind the hang, but the section's contract is the
observable guarantee (always closes, always surfaces), which survives any
change to how start-up and teardown are wired.

**Why the line-integrity criterion rides along here:** stderr and stdout are
merged before line-splitting, so in theory two writes could interleave and
corrupt a diagnostic line. In practice `ping` is line-buffered on a single
stream and this has never been observed (§req:robustness-problem-statement),
so it is hardening rather than a known defect — but it touches the same
stream-assembly code and the same observable surface (whole lines reaching
the consumer), so it is closed in the same pass rather than tracked
separately.

**Why patch-level and API-frozen:** the change is internal to
`dart_ping/lib/src/ping/base_ping.dart`; the `Ping` interface and the
`PingData` / `PingResponse` / `PingSummary` / `PingError` shapes are
unchanged, normal-run output is byte-for-byte equivalent, and failures
surface through the error channel consumers already handle. It therefore
ships as a non-breaking, patch-level release of `dart_ping` with no change
to `dart_ping_ios` (§req:robustness-constraints). A larger redesign of the
stream lifecycle was rejected as disproportionate to a focused robustness
fix (§req:robustness-priorities).

---

# Continuous integration & coverage expansion

Closes issues #74 (no CI exists) and #77 (raise coverage; some gaps need a
multi-OS host). These were deferred follow-ups tracked as GitHub issues,
now taken up together: a single cross-OS CI matrix both runs the suites
automatically (#74) and provides the multi-host environment #77 wanted,
while the same change lifts the deterministic-seam coverage that does not
need a special host.

## Cross-OS continuous integration §spec:ci
*Status: implemented — `.github/workflows/ci.yml`. Linux/Windows/macOS core
matrix, the iOS Dart suite on Linux, and the iOS Swift suite on macOS run on
every pull request to `main`. `main` is branch-protected: no direct pushes,
changes land only through a PR whose required checks are green. The Swift
job builds the example for the simulator to generate Flutter artifacts, then
runs `RunnerTests` via `xcodebuild`; its first run on a macOS runner passed,
the on-CI confirmation the §spec:ios-tests Swift suite had been pending.*

The repository runs its automated suites on every pull request to `main`,
across the host types each suite needs, and `main` cannot be changed except
through a passing PR.

- A workflow shall trigger on `pull_request` to `main` and run:
  - the core `dart_ping` suite on **Linux, Windows and macOS** — so each
    platform class's OS-specific code path is exercised on its native host
    (§spec:test-coverage, #77);
  - the `dart_ping_ios` Dart suite on Linux under `flutter test` (#74);
  - the `dart_ping_ios` Swift `RunnerTests` suite on a macOS runner via
    `xcodebuild test` (#74, §spec:ios-tests).
- The required (merge-gating) checks shall be **deterministic**: live
  ICMP round-trips to external hosts are not part of CI at all. Tests that
  spawn the system `ping` against real hosts are tagged `live` and excluded
  from every CI run (`dart test -x live`); hosted Linux/Windows runners block
  unprivileged ICMP, so those tests cannot pass there regardless, and live
  round-trips are non-deterministic everywhere. They run by default locally
  and remain the manual acceptance path. This mirrors the existing principle
  that live network behavior is not reproducible in CI (§spec:ios-tests).
- `main` shall be protected so it cannot be pushed to directly; merges
  require a pull request with the required checks passing.
- No coverage-threshold gate shall be introduced. Coverage is reported (a
  job summary), not enforced (decision carried over from §spec:test-coverage;
  the ask was reporting, not a gate).

**Why deterministic gate + informational live job rather than gating on
live pings:** a required check must be reliable or it trains maintainers to
ignore or bypass it. External `ping` results depend on the runner's network
and intermediate routers, so gating on them would make `main` un-mergeable
on a transient network blip. The OS-specific *logic* (`params`, `locale`,
exit-code interpretation) is pure and is covered deterministically
(§spec:coverage-expansion), so the gate loses no real signal by excluding
the live round trip. Running the live suite in CI was tried and removed: it
failed permanently on hosted Linux/Windows runners (no unprivileged ICMP),
producing red checks on every PR that signalled nothing — so the live suite
stays a local/manual path rather than a noisy non-gating job.

## Coverage expansion §spec:coverage-expansion
*Status: implemented — core line coverage rises from 69.9% to ~100% on the
four model files and the three platform classes on a single host; the iOS
channel bridge (`dart_ping_ios.dart`) goes from untested to 100%. Fixing the
`PingSummary` hashCode/`==` inconsistency surfaced by the new model tests is
included.*

Previously thin, deterministically-testable areas gain direct coverage,
independent of the host OS where feasible.

- The model boilerplate (`toJson`/`fromJson`/`copyWith`/`toString`/equality
  on `PingData`/`PingResponse`/`PingSummary`/`PingError`) shall be covered
  by direct unit tests, including the `toString` branches, `fromMap`
  defaults, and the non-list `errors` path (#77, model serialization).
- The OS-specific getters of `PingLinux`/`PingMac`/`PingWindows` (`params`
  with and without `count`, the Windows IPv6 `UnimplementedError`, `locale`,
  `command`, `interpretExitCode`, `throwExit`) shall be covered by tests
  that **instantiate each platform class directly**, so they run on any host
  — not only the one matching `Platform.operatingSystem` (#77). The CI
  matrix additionally runs these on each native host.
- The iOS channel bridge (`DartPingIOS`) shall be covered by tests that mock
  the `MethodChannel`/`EventChannel`, asserting the `start`/`stop`
  invocations, id-based event demultiplexing, summary-terminated stream
  close, and the cancel-stops-native-run contract (#77, iOS bridge).
- `PingSummary` shall satisfy the `a == b ⟹ a.hashCode == b.hashCode`
  contract: because `==` compares `errors` element-wise (`ListEquality`),
  `hashCode` shall hash `errors` element-wise too (it previously used the
  list's identity hash, so equal summaries could differ in hashCode).

**Why direct instantiation rather than relying on the CI matrix for the
platform getters:** routing through the `Ping()` factory only ever builds
the class for the current OS, so on any single runner two of the three
platform classes' getters stay unreached. Instantiating each class directly
makes that coverage host-independent and deterministic; the matrix then
adds genuine native execution on top, but the coverage no longer *depends*
on it. The getters are pure functions of the instance's fields, so this is
sound, not a workaround.

**Why fix the hashCode bug here:** the new equality tests are exactly what
surfaced it — `PingSummary` used `ListEquality` for `==` but the list's
identity hash for `hashCode`, so two value-equal summaries (e.g. a
deserialized one vs. its original) could land in different hash buckets,
silently breaking `Set`/`Map` membership. The fix is small and clearly
correct, the kind of latent defect the §spec:code-audit pass targets.

## CI gates pull requests to `develop` §spec:ci-develop
*Status: implemented*

The repository follows a gitflow model: feature branches merge into a
long-lived `develop` integration branch, and `develop` periodically merges
into `main` to cut a release (§req:ci-develop-problem-statement). The CI
gate (§spec:ci) previously triggered only on pull requests to `main`, which
in a gitflow model is the wrong checkpoint — a feature branch could land on
`develop` having never run the suite, so breakage accumulated on the
integration branch unseen until the `develop`→`main` release PR finally ran
CI: late, batched across many merges, and hard to attribute to the change
that caused it. This section moves the gate earlier so `develop` stays
releasable and a failure shows on the PR that introduced it.

- When a pull request targets `develop`, the CI workflow shall trigger
  automatically — no manual action — running the same job set a pull
  request to `main` runs (§req:ci-develop-success-criteria).
- The jobs run on a `develop` PR shall be at full parity with the `main`
  gate: the core `dart_ping` suite on Linux, Windows and macOS; the
  `dart_ping_ios` Dart suite on Linux; the Swift `RunnerTests` suite on
  macOS; and the informational coverage report — with the same
  deterministic, live-network-excluded behavior (`dart test -x live`) the
  `main` gate has (§spec:ci, §req:ci-develop-constraints).
- Parity shall be structural, not a maintained copy: `develop` and `main`
  are two triggers on **one** workflow definition, so the two gates cannot
  drift and there is a single place to change a job
  (§req:ci-develop-quality-attributes).
- When a change breaks a gating suite, the failure shall be visible as a
  failed required check on the `develop` PR, attributable to that change
  (§req:ci-develop-success-criteria).
- `develop` shall be branch-protected like `main`: direct pushes are
  rejected, and a PR into `develop` cannot merge until its required checks
  are green. This protection is a GitHub repository setting outside the
  workflow file but is part of this section's done state
  (§req:ci-develop-constraints).
- Adding the `develop` trigger shall leave the `main` gate unchanged — PRs
  to `main` continue to trigger and gate exactly as before, and `main`'s
  protection is untouched (§req:ci-develop-success-criteria).
- The manual `workflow_dispatch` path shall remain available
  (§req:ci-develop-priorities, nice-to-have).
- No lighter or faster subset gate, coverage-threshold enforcement, or
  change to which tests are live-excluded shall be introduced
  (§req:ci-develop-priorities, out of scope).

**Why full parity rather than a lighter fast gate:** "green on `develop`"
must mean the same thing as "green on `main`," so the `develop`→`main`
release PR is predictable — green because everything merged into `develop`
was already green, not a batched red the maintainer has to bisect
(§req:ci-develop-user-stories). A divergent reduced gate would let a class
of failure reach the release PR unguarded, defeating the purpose. Running
the full matrix on both `develop` PRs and the later release PR is an
accepted cost; runner minutes are not a constraint here
(§req:ci-develop-quality-attributes).

**Why one workflow with two branch targets rather than a second pipeline:**
a copied workflow drifts — a job fixed on one path silently rots on the
other — and the determinism guarantee of §spec:ci is inherited only if the
`develop` gate *is* that same definition. Extending the existing
`pull_request.branches` list keeps one source of truth and inherits the
live-network exclusion by construction rather than by duplicated
configuration (§req:ci-develop-constraints).

**Why branch protection is in scope despite living in repo settings:** the
problem is not just "checks run" but "nothing lands on `develop` without
them." Triggering CI without protecting the branch would still let a red or
unchecked change merge, leaving the integration branch unguarded — so the
protection setting, though configured outside `.github/workflows/ci.yml`, is
part of "done" for this capability (§req:ci-develop-problem-statement).

---

# IPv6 / address-family error clarity

Solution-space design for issue #69 (`§req:ipfamily-*`), a
correctness-of-errors fix in `dart_ping`'s address-family handling. On
IPv6-enabled networks — most visibly mobile data — pinging a literal IP
can fail with a misleading "Unknown Host" error even though no name was
being resolved, while the same target by hostname succeeds. The work is
confined to error correctness; it changes no transport mechanism and adds
no IPv6 capability where a platform lacks it.

The problem (from §req:ipfamily-problem-statement): native ping selects
its address family **exclusively** — the IPv4 tool refuses an IPv6 target
and vice-versa — and `dart_ping` already inherits that by running `ping6`
for an IPv6 selection and `ping` for IPv4 (and `-4`/`-6` on Windows). But
the library exposed the selection as an ambiguous `ipv6` boolean, never
named it an exclusive selector, never validated that a literal target's
family matches the selection, and never normalized the resulting native
failure. So a family/flag mismatch, a missing route for
the selected family, or an adapter without that family enabled all surface
as whatever generic message the platform emits — frequently "unknown
host," which sends developers chasing a name-resolution problem that does
not exist. The "hostname works but the bare IP fails" signature on
IPv6-only mobile networks (DNS64 synthesizes a routable IPv6 address for a
name; a bare IPv4 literal has no such path) is the tell.

This area resolves the platform-scope open decision deferred from
discovery (§req:ipfamily-open-decisions). Three decisions structure the
fix: (1) the family/flag-mismatch check on **literals** is
platform-agnostic and lands once in the shared Dart factory, so the error
is identical on every platform by construction; (2) hostnames are never
touched — the library still does no DNS of its own; (3) honest mapping of
routing/family failures lands per-engine (the core `dart_ping` subprocess
parsers and the `dart_ping_ios` Swift engine), where the native error
originates. The error model is preserved and any new `ErrorType` value is
additive; the address-family selector itself is deliberately redesigned —
the ambiguous `ipv6` boolean becomes an `IpVersion` enum — a breaking
change accepted to remove the ambiguity behind #69
(§req:ipfamily-constraints, §req:ipfamily-quality-attributes).

## Address family is an explicit `IpVersion` selection §spec:ipv6-address-family-selector
*Status: implemented (Batch #69-1) — the `bool ipv6` selector was replaced by a
two-value `IpVersion` enum (`ipv4`/`ipv6`, no auto/dual-stack), exported from
`dart_ping` and accepted as `Ping(ipVersion:)` defaulting to `IpVersion.ipv4`.
The selector threads through `base_ping` (`ping6` vs `ping`), the Linux/Mac/Windows
classes (Windows passes `-4` and still raises an explicit `UnimplementedError` for
`IpVersion.ipv6`), and the `dart_ping_ios` bridge (sent as the enum name over the
method channel; native family-faithful resolution lands in Batch #69-3). dartdoc
documents the exclusive-selection model. Shipped as `dart_ping` 10.0.0 /
`dart_ping_ios` 6.0.0 with CHANGELOG migration notes. Covered by network-free
platform/bridge tests (family threading + the `IpVersion.ipv4` default).*

The address family is chosen through an explicit, **exclusive**
`IpVersion` enum — `IpVersion.ipv4` or `IpVersion.ipv6` — replacing the
former `ipv6` boolean. The selection is single-family on every platform,
matching the native `ping`/`ping6` (`-4`/`-6`) semantics the library
already relies on. It defaults to `IpVersion.ipv4` (the behavior of the
former `ipv6: false` default).

- The public selector shall be an `IpVersion` enum with exactly two
  values, `ipv4` and `ipv6`; the `Ping` constructor shall accept it
  (parameter `ipVersion`, default `IpVersion.ipv4`) in place of the
  `bool ipv6` parameter
  (§req:ipfamily-success-criteria, §req:ipfamily-quality-attributes).
- The system shall treat `IpVersion.ipv6` as IPv6-only and
  `IpVersion.ipv4` as IPv4-only, consistently across iOS, Android, macOS,
  Linux, and Windows, with no dual-stack or "prefer one family" behavior
  (§req:ipfamily-success-criteria, §req:ipfamily-constraints).
- The public dartdoc shall describe `IpVersion` as an exclusive
  address-family selection, so a reader understands that `IpVersion.ipv4`
  excludes IPv6 rather than preferring IPv4
  (§req:ipfamily-success-criteria, §req:ipfamily-priorities — documentation).
- Where a platform cannot serve the requested family at all, the system
  shall surface an honest, explicit error rather than silently serving the
  other family. Windows IPv6 remains unsupported and continues to fail
  with an explicit "unsupported" error, not a misleading one
  (§req:ipfamily-constraints — no new capability;
  §spec:address-family-error-honesty).

**Why an enum instead of the `ipv6` boolean (breaking change):** the
library already selects family exclusively (`base_ping` runs `ping6` vs
`ping`; Windows passes `-4`/`-6`), but a boolean `ipv6` parameter names
only one family and leaves `false` open to being read as "prefer IPv4 /
dual-stack" — the exact misreading behind #69. An `IpVersion` enum makes
the choice symmetric and self-documenting: both families are named, and
neither value implies a preference or a fallback. Replacing the boolean is
a deliberate breaking change, shipped with a major version bump and a
migration note (`ipv6: true` → `IpVersion.ipv6`; `ipv6: false` / default →
`IpVersion.ipv4`); the one-time migration is judged cheaper than carrying
the ambiguity forward (§req:ipfamily-quality-attributes — compatibility).
This framing is what makes mismatch validation
(§spec:address-family-mismatch-validation) coherent and the "hostname
works, IP fails" surprise explicable.

**Why `IpVersion`, not `IpMode` (rejected name):** "mode" implies
behavioral modes — prefer-one-family, auto-select, dual-stack — that the
library explicitly does not offer. `IpVersion` names exactly what is
chosen: which IP version the ping uses. The narrower name forecloses the
very misreading the rename exists to remove.

**Why not a dual-stack / auto-select model (rejected alternative):**
letting the OS pick the family would require the library to resolve the
host itself and choose — exactly the DNS work the library deliberately
does not do (§req:ipfamily-constraints — thinness). Native `ping`/`ping6`
are single-family tools; an auto-select layer on top would be a
translation layer the spec explicitly avoids. A two-value `IpVersion`
keeps the library thin and faithful to native behavior, and deliberately
leaves no third "auto" value.

## Address-family mismatch fails fast §spec:address-family-mismatch-validation
*Status: implemented (Batch #69-2) — a parse-only `ipLiteralFamily()` helper
(`dart_ping/lib/src/address_family.dart`, wrapping `InternetAddress.tryParse`,
no DNS) classifies a target as an IPv4 literal, IPv6 literal, or hostname. A
synchronous guard at the top of the shared `Ping(...)` factory
(`dart_ping/lib/src/ping_interface.dart`), before the platform switch (so it
covers every engine including the iOS factory path), throws `ArgumentError`
when a literal's family contradicts the selected `IpVersion` — both directions
(`IpVersion.ipv4`+IPv6-literal and `IpVersion.ipv6`+IPv4-literal) — naming an
address-family mismatch, before any stream/process starts. A matching literal
or a hostname (`literalFamily == null`) falls through unchanged with no DNS.
Covered by network-free tests (`dart_ping/test/address_family_test.dart`,
`dart_ping/test/address_family_validation_test.dart`).*

When the target is a **literal IP address** whose family contradicts the
selected `IpVersion`, the call fails immediately with a single,
consistent, catchable error — before any ping stream starts — that names
an address-family mismatch. Hostnames are never rejected this way.

- When `IpVersion.ipv4` is selected with an IPv6 literal, **or**
  `IpVersion.ipv6` with an IPv4 literal, the system shall throw an
  `ArgumentError` before the ping stream starts, identical in shape across
  all platforms, whose message names an address-family mismatch (not
  "Unknown Host", not a hang)
  (§req:ipfamily-success-criteria, §req:ipfamily-user-stories).
- The mismatch check shall apply only to targets that parse as literal IP
  addresses, whose family is determinable without resolution; a target
  that is not an IP literal (a hostname) shall be passed through unchanged,
  with no DNS performed by the library
  (§req:ipfamily-constraints, §req:ipfamily-quality-attributes — thinness).
- A literal whose family **matches** the selection (e.g. `IpVersion.ipv4`
  with an IPv4 literal) and any hostname shall start the ping exactly as
  they do today (§req:ipfamily-success-criteria — regression guards).
- This validation shall be exercised by automated tests that require no
  live network — a literal target plus a selected `IpVersion` is pure input
  (§req:ipfamily-success-criteria, §req:ipfamily-priorities — tests;
  §spec:address-family-error-tests).

**Why a synchronous `ArgumentError` rather than a stream error event:** a
selected family that contradicts a literal target is a programming error
in the *call*, knowable before any process launches and detectable without
a network. Surfacing it as a thrown `ArgumentError` lets the caller catch it
at the call site and keeps it distinct from runtime network failures,
which belong on the stream's error channel
(§spec:address-family-error-honesty). The library throws no `ArgumentError`
today, so this is additive.

**Why in the shared Dart factory, not per-engine:** placing the check once
at the `Ping(...)` boundary makes the error identical on every platform by
construction — the must-have cross-platform-consistency criterion
(§req:ipfamily-quality-attributes — consistency) — and pre-empts the
divergent native mislabeling a mismatched literal would otherwise produce
(macOS's IPv4 `ping` echoes a mismatched IPv6 literal as "Unknown host";
Linux reports an address-family error). Per-engine checks were rejected:
they would duplicate logic and re-introduce the cross-platform divergence
this fix exists to remove.

**Why literals only, both directions:** a literal's family is decidable by
parsing alone (no resolution), so validating it honors the no-DNS
thinness constraint; a hostname's family is not knowable without the
resolution the library refuses to do, so hostnames are left to the
platform. The requirement is symmetric — both `IpVersion.ipv4`+IPv6-literal
and `IpVersion.ipv6`+IPv4-literal are caller errors — so both are rejected.
"Auto-correcting" the selection to match the literal was rejected: it would
hide a caller bug and could silently ping a different family than intended.

## Errors name the real failure §spec:address-family-error-honesty
*Status: implemented (Batch #69-3) — added the additive `ErrorType.noRoute`
('No Route'), distinct from `unknownHost` and the catch-all `unknown`. The core
Linux/Mac/Windows parsers now reclassify native routing / address-family messages
(network unreachable, no route to host, destination host unreachable, address
family unavailable) from `unknown` into `noRoute` via a new additive
`PingParser.noRouteStrs` list checked after `unknownHostStr` and before the
generic `errorStrs`, so `unknownHost`/`unknownHostStr` stay reserved for genuine
name resolution and Windows IPv6 keeps its explicit `UnimplementedError`. On iOS
the Swift engine resolves and sends for the selected `IpVersion` family (full
native ICMPv6 echo path added — never silently resolving the other family) and
maps `getaddrinfo` status + `sendto` errno honestly (`EAI_NONAME`/`NODATA`/`FAIL`/
`AGAIN` → `unknownHost`; `EAI_ADDRFAMILY`/`FAMILY` and
`ENETUNREACH`/`EHOSTUNREACH`/`EAFNOSUPPORT`/`EADDRNOTAVAIL` → `noRoute`) instead of
collapsing every failure to `unknownHost`. A working hostname ping (incl. a
DNS64-synthesized address) is unchanged. Covered by network-free tests on the core
parser seam and both iOS seams. Swift is hand-verified on the Linux host (macOS CI
compiles it). The literal-vs-selection `ArgumentError`
(§spec:address-family-mismatch-validation) is separate (#69-2).*

`unknownHost` is reserved for genuine name-resolution failures. Routing
and address-family failures surface as their own honest, typed errors so a
consumer can tell "that host does not exist" apart from "this network has
no route for the family you asked for."

- The system shall emit `ErrorType.unknownHost` / "Unknown Host" only for a
  genuine name-resolution failure of a real hostname — never for an IP
  literal, and never for a routing or address-family failure
  (§req:ipfamily-success-criteria — "Unknown host means what it says").
- When the network or adapter cannot route the selected family (IPv6
  disabled, no route, network unreachable), the consumer shall receive the
  platform's real failure, and recognizable cases shall be reported as a
  typed `PingError` distinct from `unknownHost` and the catch-all
  `unknown`, so cross-platform code can branch on them
  (§req:ipfamily-success-criteria — "real failures surface faithfully",
  §req:ipfamily-priorities — high).
- Any new typed error introduced for these cases shall be **additive** to
  `ErrorType` / `PingError`; existing values keep their current meaning and
  the public model shapes are unchanged
  (§req:ipfamily-constraints, §req:ipfamily-quality-attributes —
  compatibility).
- On iOS, the native engine shall stop collapsing every host-resolution
  failure into `unknownHost`: a genuine name-resolution failure maps to
  `unknownHost`, while an address-family / no-route condition maps to its
  honest typed error. The engine shall resolve and send for the family the
  selected `IpVersion` requests, or — where it cannot serve that family —
  surface an honest error rather than silently resolving the other family
  (§req:ipfamily-success-criteria, §req:ipfamily-problem-statement).
- A hostname ping that works today — including one that resolves to a
  DNS64-synthesized address on an IPv6-only network — shall continue to
  work unchanged (§req:ipfamily-success-criteria — regression guard).

**Why this is the core of #69:** the reported signature is "hostname
works, bare IP fails with Unknown Host." That happens because the failure
is an address-family / routing problem mislabeled as name resolution. The
core subprocess parsers already have the seam to keep `unknownHost` honest
(a dedicated `unknownHostStr` pattern, separate `errorStrs`, and
exit-code interpretation); the gap is that routing failures land in the
catch-all `unknown` instead of a branchable typed error, and that iOS
maps *all* `getaddrinfo` failures — including address-family and no-route
errors — to `unknownHost`. Distinguishing the resolution error code on iOS
and giving routing/family failures a typed category restores error honesty
(§req:ipfamily-quality-attributes — error honesty).

**Scope boundary — honesty, not new capability:** this section guarantees
the error tells the truth; it does **not** promise IPv6 reachability where
a platform or network cannot provide it (§req:ipfamily-constraints). On an
IPv6-only mobile network, an IPv4 literal ping legitimately has no route —
the deliverable is that the consumer learns "no route for this family,"
not a phantom "unknown host." Windows IPv6 stays an explicit unsupported
error (§spec:ipv6-address-family-selector).

**Why keep the library thin here too:** the library normalizes only at the
Dart boundary — reserving `unknownHost`, mapping recognizable native
errors to typed values — and otherwise passes the platform's real failure
through. It adds no DNS, no retries, and no family fallback
(§req:ipfamily-quality-attributes — thinness / native fidelity).

## Address-family error tests §spec:address-family-error-tests
*Status: implemented — both bullets land. The literal-vs-selection validation
bullet landed in Batch #69-2 (`dart_ping/test/address_family_validation_test.dart`):
deterministic, network-free cases asserting an IPv6 literal with
`IpVersion.ipv4` and an IPv4 literal with `IpVersion.ipv6` each throw
`ArgumentError` (including the `IpVersion.ipv4` default), while a matching
literal and a hostname each construct without throwing. The error-mapping bullet
landed in Batch #69-3 (`dart_ping/test/address_family_error_test.dart`): native
outputs fed through each platform parser (routing / no-route lines → `noRoute`; a
genuine unknown-host line → `unknownHost`; an ambiguous line → `unknown`), with the
iOS seams covered by `dart_ping_ios/test/ping_event_mapper_test.dart` (a
`'No Route'` error/summary event → `ErrorType.noRoute`) plus the Swift
`RunnerTests` (`errorKind(forGetaddrinfoStatus:)` / `errorKind(forSendErrno:)`
mapping and ICMPv6 framing vectors, network-free, run by macOS CI).*

The mismatch validation and the error mapping are covered by automated
tests that do not require a live IPv6-only network.

- Literal-vs-selection validation shall be covered by deterministic tests
  over pure input: an IPv6 literal with `IpVersion.ipv4` and an IPv4
  literal with `IpVersion.ipv6` each throw `ArgumentError`; a matching
  literal and a hostname each do not (§req:ipfamily-success-criteria,
  §req:ipfamily-priorities — high; §spec:address-family-mismatch-validation).
- The error mapping shall be covered by feeding representative native
  outputs (address-family / no-route messages, and a genuine
  unknown-host message) through the parser/mapper and asserting the
  resulting `ErrorType`, with no live process required
  (§req:ipfamily-success-criteria — automated tests;
  §spec:address-family-error-honesty).

**Why deterministic seams only:** the live failure modes (#69's actual
IPv6-only-mobile-data conditions) cannot be reproduced in CI — hosted
runners block unprivileged ICMP and have no IPv6-only network
(§spec:ci). The testable surface is the pure logic: literal/selection
validation (string + `IpVersion` in → throw-or-not) and native-string →
typed error mapping. This mirrors the existing principle that live network
behavior is a manual acceptance path, not a CI gate (§spec:ios-tests).

---

# Interface selection

Solution-space design for issue #72 (`§req:interface-*`): let a consumer
choose which network interface — or which local source address — pings
originate from, instead of always taking the OS default route. The work is
confined to the core `dart_ping` package's subprocess platforms
(Linux/Android, macOS, Windows) plus an explicit iOS rejection; it adds an
optional parameter and a listing helper and changes no existing behavior.

The problem (from §req:interface-problem-statement): on a multi-homed host —
Wi-Fi and Ethernet at once, a VPN/tunnel alongside a physical NIC, cellular
vs. Wi-Fi on mobile/embedded — `dart_ping` offers no way to say "send these
pings out of *this* interface," even though the system `ping` binaries it
drives already support it (Linux's `-I`). A developer who needs to verify
reachability over a specific path must shell out to `ping` themselves or
re-route the host. A secondary gap: developers often don't know the exact
interface names/addresses on the current host, and those differ per platform.

The design adds one optional `interface` selection to the `Ping` factory,
threaded through to each platform class, where it maps onto that platform's
native binding flag. The single value accepts **either** an interface name
**or** a local source IP address; each platform honors the form(s) its
`ping` can bind by and rejects — loudly — the form(s) it cannot. A
nice-to-have static helper enumerates the host's interfaces. The selection
reuses the existing per-platform `params`/`command` assembly and the
stream-error/termination guarantees of §spec:stream-lifecycle-robustness;
it introduces no new public model types and no new failure-reporting
mechanism.

**Why one `interface` parameter that takes a name or an address** rather
than two parameters (`interface` + `sourceAddress`): the underlying tools
blur the distinction — Linux `ping -I` accepts a name or an address in the
same flag — and the user thinks in terms of "the path to ping from," not
"which of two binding mechanisms." A single value classified by whether it
parses as an IP literal (`InternetAddress.tryParse`) lets each platform pick
the flag it supports from one input, keeping the cross-platform call
identical (§req:interface-quality-attributes — cross-platform
predictability; §req:interface-constraints). Two parameters would push the
name-vs-address mechanism choice onto the caller, which is exactly the
platform detail this design hides.

## Interface selection on the subprocess platforms §spec:interface-selection
*Status: implemented (dart_ping 9.2.0) — an optional `interface` value on the `Ping` factory and the `PingLinux`/`PingMac`/`PingWindows` constructors is classified as a name vs. a source address via `InternetAddress.tryParse` (shared `BasePing.interface` field + `interfaceIsAddress` getter) and mapped onto each tool's binding flag inside the existing `params` getter: Linux/Android `-I <value>` (either form), macOS `-b <value>` (name) / `-S <value>` (address), Windows `-S <value>` (address form only — bare-name rejection is §spec:interface-platform-rejection). Omitting `interface` leaves `params`/`command` byte-for-byte identical to 9.1.1; the iOS factory branch and the `PingData`/`PingResponse`/`PingSummary`/`PingError` shapes are unchanged. Covered by network-free `dart test` cases in `dart_ping/test/platform_test.dart` asserting the per-platform flag for name and address selections plus a backward-compat guard, all via the public `command`/`params` getters.*

A `Ping` constructed with an optional `interface` value pins its probes to
that interface or source address on the platforms whose `ping` can bind by
the supplied form. The value is a single string holding either an interface
name (e.g. `eth0`, `en0`) or a local source IP (e.g. `192.168.1.5`),
classified by whether it parses as an IP literal. Omitting it reproduces
today's behavior exactly.

- When a caller supplies an `interface` value, the spawned ping command
  shall carry the platform's interface-binding flag for that value, so
  probes originate from the chosen interface/source rather than the OS
  default route (§req:interface-success-criteria,
  §req:interface-user-stories):
  - **Linux/Android** binds either form with `-I <value>` (the platform's
    `ping -I` accepts a name or an address).
  - **macOS** binds an interface name with `-b <value>` (boundif) and a
    source address with `-S <value>`.
  - **Windows** binds a source address with `-S <value>`; the name form is
    not supported here and is rejected (§spec:interface-platform-rejection).
- The selection accepts a name or a source address, and both forms work
  wherever the platform supports them (Linux/Android: both; macOS: both;
  Windows: address only) (§req:interface-success-criteria — must-have).
- When no `interface` is supplied, the produced command and the stream's
  behavior shall be byte-for-byte identical to the current release, so
  existing consumer code is unaffected (§req:interface-success-criteria —
  backward-compatibility guard; §req:interface-quality-attributes —
  compatibility).
- The addition shall be a new **optional** parameter on the `Ping` factory
  and the platform constructors; the `Ping` interface and the
  `PingData` / `PingResponse` / `PingSummary` / `PingError` shapes are
  otherwise unchanged, and the feature ships as a **minor** version of
  `dart_ping` (§req:interface-constraints, §req:interface-quality-attributes
  — compatibility, §spec:public-api-stability).
- The command produced for a given selection shall be assertable via the
  public `command` getter without a live network, so each platform's flag
  mapping is unit-testable (§req:interface-quality-attributes — testability).

**Why map onto each platform's native flag rather than a portable
abstraction:** `dart_ping` is a thin driver over the system `ping`; the
binding is whatever that binary offers. Reusing the existing per-platform
`params` getter (where `-O`/`-W`/`-i`/`-t` etc. already live) keeps the
interface flag beside the flags it sits next to and makes it testable the
same way (§spec:coverage-expansion asserts `params`/`command` directly). The
flag choices — Linux `-I`, macOS `-b`/`-S`, Windows `-S` — are the project's
mapping decision from the one `interface` value onto each tool, recorded
here so the *why* survives even if a flag spelling changes upstream.

**Why classify name vs. address by parsing the value** rather than asking
the caller to declare which it is: it removes a decision the caller would
otherwise have to make per platform, and the classification is cheap and
unambiguous (an IP literal parses; a name does not). It also lets one shared
call site work across Linux, macOS, and Windows, with only Windows narrowing
to the address form — the cross-platform-predictability goal
(§req:interface-quality-attributes).

**Tradeoff:** `interface` is named for the user's mental model even though it
also accepts a source address, because "interface" is the issue's and the
domain's term (#72) and the address form is the less common path. The
doc comment states both forms explicitly so the dual meaning is discoverable
at the call site.

## Loud rejection of unsupported selections §spec:interface-platform-rejection
*Status: implemented (dart_ping 9.2.0) — a selection a platform cannot honor now fails loudly through a catchable error rather than a silent no-op. On Windows, `PingWindows.params` throws an `UnimplementedError` for a bare interface *name* (any non-null `interface` that is not an IP address) naming the limitation — Windows `ping` binds only by source address — while the `-S <address>` source form stays honored (§spec:interface-selection); because `params` is evaluated inside `BasePing._onListen`'s try/catch, the throw surfaces on the stream's error channel and the stream still closes (mirrors the existing IPv6 `UnimplementedError` precedent). On iOS, a new top-level `throwIfInterfaceUnsupportedOnIos(interface)` guard — called as the first statement of the `Ping` factory's `'ios'` branch, before delegating to `Ping.iosFactory` — throws `UnimplementedError('Interface selection is not supported on iOS')` for any non-null selection, so the `dart_ping_ios` factory signature and the native engine need no edit. A bad/non-existent interface (OS `ping` refusing the bind / non-zero exit) reuses the §spec:stream-lifecycle-robustness error-channel + bounded-time close with no new failure-reporting mechanism. Covered by network-free `dart test` cases: the Windows name rejection in `dart_ping/test/platform_test.dart`, the iOS guard (name, address, and null no-op) in `dart_ping/test/misuse_test.dart`, and the bad-interface error-then-close path in `dart_ping/test/stream_lifecycle_test.dart`.*

A selection a platform genuinely cannot honor produces a clear, catchable
error and the stream terminates — never a silent no-op that misleads the
caller into thinking a binding took effect.

- On **Windows**, supplying a bare interface *name* (a value that is not an
  IP address) shall produce an explicit, catchable error naming the
  limitation — Windows `ping` binds only by source address — rather than
  silently ignoring the request or pinging the default route
  (§req:interface-success-criteria — must-have;
  §req:interface-quality-attributes — discoverability). The source-address
  form is honored (§spec:interface-selection).
- On **iOS**, supplying any `interface` selection shall produce an explicit
  "interface selection not supported" error, so a developer is never misled
  into thinking a selection took effect on a platform whose engine cannot
  bind one (§req:interface-success-criteria — must-have). This mirrors how
  Windows rejects IPv6 today.
- When the chosen interface or source address does not exist or has no
  connectivity, the consumer shall receive a catchable error event on the
  stream and the stream shall then close within bounded time — no hang —
  reusing the termination and error-channel guarantees of
  §spec:stream-lifecycle-robustness (§req:interface-success-criteria;
  §req:robustness-success-criteria).
- The per-platform rejections and the bad-interface error path shall be
  covered by automated tests that do not require specific live hardware
  (e.g. asserting the rejection for a Windows name selection and an iOS
  selection) (§req:interface-quality-attributes — testability).

**Why fail loudly instead of approximating or ignoring:** a silently dropped
selection is the worst outcome — the developer believes pings traverse the
chosen path when they take the default route, defeating the diagnostic the
feature exists for (§req:interface-problem-statement). Rejecting the
unsupported form is consistent with the package's existing stance on
capabilities a platform lacks: `PingWindows.params` already throws
`UnimplementedError` for IPv6 rather than emitting a wrong command. The
unsupported-selection rejection follows that precedent and surfaces through
the same stream error channel, so §spec:stream-lifecycle-robustness
guarantees it is catchable and the stream still closes.

**Why reject iOS at the factory boundary:** the iOS engine
(§spec:swift-icmp-engine) exposes no interface binding, and pinning one
there is separately out of scope (§req:interface-constraints). Rejecting the
selection in the `Ping` factory's iOS branch — before delegating to
`Ping.iosFactory` — keeps the `dart_ping_ios` factory signature and the
native engine unchanged, so the iOS package needs no edit to stay correct
(§spec:public-api-stability). A future iOS implementation can lift the
rejection without a breaking change.

**Why "does not exist / no connectivity" rides the existing error path:**
that failure is the OS `ping` refusing the bind or exiting non-zero, which
is already routed through the stream's error channel and bounded-time
closure by §spec:stream-lifecycle-robustness. The feature deliberately adds
no new failure-reporting mechanism (§req:interface-constraints).

## Enumerating available interfaces §spec:interface-listing
*Status: implemented (dart_ping 9.2.0) — a top-level `listNetworkInterfaces({includeLoopback, includeLinkLocal, type})` helper in `dart_ping/lib/src/interface_listing.dart`, exported from `dart_ping/lib/dart_ping.dart`, returns the host's `dart:io` `NetworkInterface`s via `NetworkInterface.list()` (no `ifconfig`/`ip`/`ipconfig` parsing). Each returned interface exposes a `name` and `addresses`, either of which feeds straight back into a `Ping`'s `interface` value; the entrypoint re-exports `NetworkInterface`/`InternetAddress`/`InternetAddressType` so the return type is nameable without importing `dart:io`. No new public model type is introduced. The helper is a thin pass-through with no `try/catch`, so an enumeration failure propagates to the caller as a rejected future rather than being swallowed; that failure path is made testable network-free via an internal `networkInterfaceLister` seam (typedef + mutable top-level default, reachable from `package:dart_ping/src/interface_listing.dart` but not from the public entrypoint). Covered by network-free `dart test` cases in `dart_ping/test/interface_listing_test.dart` (exported surface/shape, round-trip of a returned name/address into `Ping(host, interface: ...)`, and the not-swallowed-failure contract via the seam). Documented in the README ("Selecting a network interface") and the 9.2.0 CHANGELOG entry.*

A developer can discover the network interfaces available on the current
host — enough to identify one and pass it back into a `Ping` — so an app can
present a chooser or validate caller input.

- The package shall expose a helper that returns the host's available
  network interfaces, each identified well enough (name and/or addresses) to
  be supplied as the `interface` value of a `Ping`
  (§req:interface-success-criteria — nice-to-have;
  §req:interface-user-stories).
- The helper shall surface no new public model coupling beyond what
  enumeration requires, and a failure to enumerate shall be reported to the
  caller rather than swallowed (§req:interface-quality-attributes —
  reliability, discoverability).

**Why a listing helper at all:** selecting an interface is only useful if
the developer knows which names/addresses exist, and those differ per
platform (§req:interface-problem-statement). The helper closes the loop
between "I want to pick an interface" and "I don't know what's available."

**Why build on `dart:io`'s `NetworkInterface.list()` rather than parse
`ifconfig`/`ip`/`ipconfig` output:** the Dart SDK already enumerates
interfaces and their addresses portably across the desktop platforms,
returning structured data, so reusing it avoids a second per-platform
text-parsing surface (the kind §spec:ttl-exceeded-parse showed is
error-prone) and stays consistent regardless of locale. The helper's exact
return shape is an implementation choice; the normative contract is only
that what it returns can be fed back into `interface`.

**Why nice-to-have, not must-have:** the core value is the selection itself
(§spec:interface-selection); a developer who already knows their interface
name can use the feature without the listing helper. It is therefore
prioritized below the selection and its rejections (§req:interface-priorities)
and can ship in the same or a later slice without blocking them.

---

# Concurrent-ping isolation

Solution-space design for issue #70 (`§req:concurrent-*`): a reported
correctness defect where two or more `Ping` instances running at the same
time report the same round-trip results instead of each host's own. First
observed on Android. The work is confined to the existing packages and
changes no public surface; it is independent of the #73 iOS work and the
rest of the refresh.

The problem (from §req:concurrent-problem-statement): a developer pinging
several hosts at once — one `Ping` per host, awaited together — reports
that the concurrent results are cross-contaminated. Each response carries
the correct destination IP, but the round-trip time is identical across
hosts; pinging the same hosts one at a time returns the correct, distinct
times. The failure is silent and plausible — no error, valid shape, right
IPs — so callers that pick the "fastest" host or chart latency act on
fabricated numbers (§req:concurrent-user-stories).

## Concurrent ping isolation §spec:concurrent-isolation
*Status: complete (both halves) — confirm-then-decide gate ran on each engine and required no production change. Core/subprocess: the offline guard `dart_ping/test/concurrent_isolation_test.dart` overlaps concurrent `Ping` runs with canned interleaved per-host output and asserts no field bleeds; it passes against the current source, confirming the design-level isolation invariant (no shared mutable state in `BasePing`). iOS bridge: `dart_ping_ios/test/concurrent_isolation_test.dart` overlaps two `DartPingIOS` runs over the single shared broadcast `EventChannel`, recovers each run's id from its `start` call, pushes INTERLEAVED distinctly-id'd events (responses, an error, and a summary per run), and asserts each run's stream receives only its own id's events (own seq/ttl/time/ip; own summary transmitted/received/time + errors) and never a sibling's, and that each stream still closes on its own summary — confirming the id-demux is isolation-correct (each `_onListen` filters the shared stream by its own unique per-run `_id`). Both tests stand as permanent offline regression guards.*

Concurrent `Ping` instances are fully independent: when several runs to
distinct hosts overlap in time, every event a stream emits — response,
error, and summary — carries only its own host's data, identical to what
that host returns when pinged alone. No field is ever copied from a
sibling run. A network-free automated test holds this invariant so the
class of bug cannot quietly return.

- When N `Ping` instances to distinct hosts run at the same time, each
  stream's responses shall carry that host's own `seq`, `ttl`, `time`,
  and `ip`, matching what the same host returns when pinged sequentially;
  no field shall be copied from a concurrently-running sibling
  (§req:concurrent-success-criteria, §req:concurrent-quality-attributes —
  correctness).
- Each concurrent run's `PingSummary` (`transmitted`/`received`/`time`)
  and its `PingSummary.errors` list shall reflect only that run; an error
  or count from one ping shall not appear in another's summary
  (§req:concurrent-success-criteria).
- Sequential pinging — one host at a time — shall return the same correct,
  distinct results as before; this fix changes nothing for sequential
  callers (§req:concurrent-success-criteria — regression guard,
  §req:concurrent-user-stories).
- The isolation guarantee shall hold wherever `dart_ping` runs — Android,
  Linux, macOS, and Windows (the shared subprocess engine) and iOS
  (§req:concurrent-success-criteria, §req:concurrent-quality-attributes —
  cross-platform consistency).
- An automated test runnable under `dart test` shall overlap multiple ping
  streams without a live network and **fail if results cross-contaminate**,
  so a regression is caught offline rather than only on a device
  (§req:concurrent-success-criteria,
  §req:concurrent-quality-attributes — testability).
- The public Dart API is unchanged: the `Ping` interface and the
  `PingData` / `PingResponse` / `PingSummary` / `PingError` shapes keep
  their current form, and existing concurrent and sequential call sites
  keep working without edits (§req:concurrent-constraints,
  §spec:public-api-stability).

**Why isolation holds by construction (the technical finding):** each
`Ping` instance owns only instance-local state. In the core subprocess
path (`§spec:public-api-stability` → `BasePing`) every run has its own OS
process — hence its own `stdout`/`stderr` pipes — its own
`StreamController`, its own parser instance (`defaultParser` is a per-call
factory, not a shared singleton), and its own `_errors`/`_summaryData`
accumulators. There is no `static` or otherwise shared mutable state in
that path, in either the current code or the pre-#76 code the report
predates. On iOS the bridge shares a single broadcast `EventChannel`
across instances but demultiplexes by a unique per-run id, delivering each
controller only the events whose `id` matches its own run
(§spec:ios-ping-behavior). Because no library state is shared between
runs, results cannot bleed through it — the invariant above is a property
of the design, and this section's job is to make it explicit and guarded.

**Why confirm-then-decide rather than "fix the bug" directly
(§req:concurrent-priorities — first gate):** the root cause is not
established and the report predates the #76 stream-lifecycle and
stream-assembly rework, so it is not yet known whether the defect still
reproduces. Since no shared mutable state is evident, the most plausible
outcome is that the current release is already isolated. The first step is
therefore an offline regression test that overlaps streams and asserts
isolation: it either reproduces a real residual defect — in which case the
source is fixed before the test is allowed to pass — or it confirms the
invariant and stands as the permanent guard. The durable deliverable is
the test and the documented invariant; new production code is contingent
on the test actually reproducing a defect, not assumed up front.

**Why a network-free test rather than a live multi-host integration test:**
live ICMP round-trips are non-deterministic — they depend on the network
and intermediate routers — and unprivileged ICMP is blocked on hosted CI
runners, so a live test could not gate `main` reliably (§spec:ci,
§spec:ios-tests). The deterministic seam is each instance's
output-assembly-and-parse path: driving two or more runs with canned,
distinct per-host output and interleaving them exercises exactly the
per-instance accumulation (`_errors`, `_summaryData`, the response stream)
where cross-contamination would surface, and fails offline if any run's
data appears in another's stream.

**Scope and tradeoffs:** this is a correctness fix, not a feature — the
public API stays frozen and no built-in multi-host helper is introduced
(§req:concurrent-constraints). Two alternatives were rejected. Closing the
issue as "already fixed" without a test was rejected: it leaves a
high-impact, silent class of bug unguarded against future refactors that
might introduce shared state. Gating on a live multi-host ping was
rejected as non-deterministic and CI-hostile, for the reasons above. The
isolation guarantee is the normative contract; the specific mechanism by
which each run stays independent (separate processes today, the iOS id
demux) is implementation detail that may change without invalidating this
section.

---

# Summary statistics

Solution-space design for issue #63 (`§req:stats-*`): surface the
round-trip statistics the native `ping` already prints — min / avg / max /
stddev — plus a jitter figure and a packet-loss percentage, both in the
terminal run summary and as live running figures during a run, with full
cross-platform parity including iOS. The work is delivered as a
from-scratch redesign of the stream's event/data classes, ridden in on the
already-unreleased breaking majors (`dart_ping` 10.0.0 / `dart_ping_ios`
6.0.0 — the same majors the #69 address-family work bumped to).

The problem (from §req:stats-problem-statement): the native `ping` binary
prints a round-trip summary at the end of every session, and that is
exactly what a diagnostics UI wants to show — but `dart_ping` discards it.
`PingSummary` exposes only `transmitted` / `received` / total `time` /
`errors`, so a developer who wants min / avg / max / stddev, jitter, or a
loss percentage must reconstruct them by hand from the per-probe stream.
min / max are easy; stddev and jitter are not. Three things make the
do-it-yourself path worse than it looks: the raw material is lossy
(per-probe `time` truncates to whole milliseconds through `toMap`), there
is no running view (stats only make sense at the end today), and the event
shape resists extension — a single `PingData` with three nullable fields,
where end-of-run is detected by `summary != null`, cannot carry a
summary-so-far on every probe without breaking the very signal consumers
rely on.

This area resolves the four open decisions deferred from discovery
(§req:stats-open-decisions): the event/value-object shapes
(§spec:stats-event-model, §spec:stats-round-trip), native-vs-computed
precedence (§spec:stats-cross-platform), the precision-preserving
serialization (§spec:stats-precision), and the iOS surfacing mechanism
(§spec:stats-ios).

**This area supersedes the API-stability promises of the earlier work.**
Areas 1–7 above each assert the `PingData` / `PingResponse` / `PingSummary`
/ `PingError` shapes stay unchanged (§spec:public-api-stability and its
echoes through §spec:concurrent-isolation). Those promises were scoped to
the same unreleased 10.0.0 / 6.0.0 window and are deliberately overridden
here: the public event/data shape changes once, in this redesign, as part
of that major, rather than each earlier area preserving the old shape
(§req:stats-constraints).

## Sealed ping-event stream §spec:stats-event-model
*Status: implemented (dart_ping 10.0.0) — the nullable `PingData` envelope is replaced by a `sealed class PingEvent` with three `final` subtypes: `PingResponse` (successful probe), `PingError` (probe/run error, now also carrying optional `seq`/`ip` so a self-identifying timeout/TTL probe stays a single event), and the terminal `PingSummary`. Each variant writes a `'type'` discriminator so `PingEvent.fromMap`/`fromJson` reconstruct the right subtype; the three files are a part/part-of library rooted at `ping_event.dart`. The stream (`Ping.stream`, `BasePing`, the parser transformer) is now `Stream<PingEvent>`, consumers branch with an exhaustive `switch`, and the summary is identifiable by type alone (`is PingSummary`) as the final event. Covered by network-free `dart test` cases in `dart_ping/test/{model_test,serialization_test,parse_test,stats_event_test}.dart`.*

A `Ping` instance's stream emits a **sealed `PingEvent`** union with three
explicit variants — a probe response, a probe error, and a terminal run
summary — replacing the single `PingData` whose three nullable fields
(`response` / `summary` / `error`) consumers had to disambiguate by hand. A
consumer branches on the event's type (an exhaustive `switch`) and the
terminal summary is the identifiable final event of the run.

- The stream shall emit `PingEvent` values of exactly three kinds — a
  successful-probe response, a probe/run error, and a terminal run summary
  — and the type of each event shall make its kind explicit, so a consumer
  distinguishes them without inspecting which fields are null
  (§req:stats-success-criteria — unambiguous end-of-run;
  §req:stats-user-stories; §req:stats-priorities — must-have).
- The run-summary event shall be the final event emitted before the stream
  closes, and identifiable as terminal by its type alone
  (§req:stats-success-criteria — terminal event identifiable).
- A probe that both identifies a probe and reports an error (a timed-out or
  TTL-exceeded probe carrying a `seq` and/or a hop `ip`) shall remain
  representable as a single error event that also carries that partial
  probe information, preserving the existing combined response+error
  contract (§spec:ios-error-parity, §spec:address-family-error-honesty;
  §req:stats-success-criteria — no information lost).
- The per-probe `seq` / `ttl` / `time` / `ip`, the run summary's
  `transmitted` / `received` / total `time` / `errors`, and the per-run
  error list shall all remain available after the reshape; no result
  information is lost (§req:stats-success-criteria — existing information
  preserved).
- The redesigned event shape is a **breaking** change to the public Dart
  surface, shipped in `dart_ping` 10.0.0 / `dart_ping_ios` 6.0.0
  (§req:stats-constraints; supersedes §spec:public-api-stability).

**Why a sealed union instead of extending `PingData`:** the current
end-of-run signal *is* `summary != null`, so attaching a summary-so-far to
every probe — the live-stats requirement (§spec:stats-live) — would make
every probe look like the end of the run. The nullable-field shape cannot
grow a running summary without breaking the terminal signal. A sealed
hierarchy gives each event an explicit type, lets the terminal summary be a
distinct type rather than "the event where `summary` happens to be set,"
and lets the compiler enforce exhaustive handling. Dart sealed classes are
available on the package's SDK floor (≥3.8.0, §spec:sdk-floor), so this
needs no floor change.

**Why fold it into the unreleased major rather than add fields
compatibly:** any field-additive workaround (e.g. a parallel
`runningSummary` field) would carry the ambiguity forward forever. Because
the next release is already breaking (§req:stats-constraints — the release
consolidates all post-9.0.1 changes into 10.0.0 / 6.0.0), #63 is the
occasion to adopt the shape the stream would have if built today, at no
incremental compatibility cost.

**Tradeoff:** every consumer's stream-handling code must migrate from
null-checks to a type switch. This is the one-time cost of removing the
ambiguity; it is paid once, inside a release that already forces a
migration, and the result is code the compiler checks for completeness.

## Round-trip statistics value object §spec:stats-round-trip
*Status: implemented (dart_ping 10.0.0) — a single immutable `RoundTripStats` value object in `dart_ping/lib/src/models/round_trip_stats.dart` carries min/avg/max/**population** stddev/jitter plus the successful-`sampleCount`, computed incrementally by `RoundTripStatsAccumulator` so the batch (`RoundTripStats.fromSamples`) and one-at-a-time paths are identical. Honors the null/absent contract (0 samples → all figures null; 1 sample → stddev `Duration.zero`, jitter null; ≥2 → all present) and serializes Durations in microseconds to preserve sub-millisecond precision. Covered by network-free `dart test` cases in `dart_ping/test/round_trip_stats_test.dart`.*

A single reusable value object — `RoundTripStats` — carries the round-trip
figures: **minimum, average, maximum, standard deviation, jitter**, and the
**sample count** they were computed from. The same object is used for the
final summary (§spec:stats-summary) and for the live running snapshot
(§spec:stats-live), and it is computed incrementally as probes arrive.

- `RoundTripStats` shall expose round-trip `min`, `avg`, `max`, `stddev`,
  and `jitter` (each a `Duration`) and the count of successful samples they
  summarize (§req:stats-success-criteria — full statistic set;
  §req:stats-constraints — single reusable value object).
- The statistics shall be computed over **successful replies only**: a
  timed-out, TTL-exceeded, or otherwise errored probe contributes to the
  counts and to packet loss (§spec:stats-summary) but not to
  min / avg / max / stddev / jitter (§req:stats-constraints).
- `stddev` shall be the **population** standard deviation of the successful
  round-trip times (dividing by the sample count), matching what the native
  `ping` tools report, so a computed value is comparable to the native
  number a user may have seen (§req:stats-quality-attributes — native
  fidelity).
- `jitter` shall be the **mean of the absolute differences between
  consecutive successful probe round-trip times** (RFC 3550-style
  interarrival variation), and this definition shall be documented in the
  public dartdoc so a consumer knows what they are charting
  (§req:stats-success-criteria — jitter means probe-to-probe variation,
  documented; §req:stats-constraints).
- When a run has **no successful replies**, the round-trip figures
  (`min` / `avg` / `max` / `stddev` / `jitter`) shall be reported as absent
  (null) rather than as fabricated zeros, with the sample count zero
  (§req:stats-success-criteria — zero-reply runs report honestly). With a
  single successful reply, `jitter` (which needs two samples) is likewise
  absent.

**Why one value object shared by the summary and the live snapshot:** the
running figures and the final figures are the same quantities at different
points in time. Modeling them as one type computed by one incremental
accumulator guarantees the live view and the final summary can never define
"avg" or "stddev" differently, and means the math is written and tested
once (§req:stats-quality-attributes — consistency, testability).

**Why population stddev and an explicit jitter definition:** "stddev" and
"jitter" are ambiguous across tools — Linux `ping` prints `mdev` (mean
*deviation*), macOS prints a true standard deviation, Windows prints
neither, and "jitter" has several field definitions. Pinning stddev to the
population formula the native tools use, and jitter to the RFC 3550 mean
consecutive delta, makes the library's numbers well-defined and documented
rather than "whatever the platform happened to print"
(§req:stats-quality-attributes; this is what makes uniform cross-platform
computation, §spec:stats-cross-platform, coherent).

**Why absent rather than zero on an empty sample:** a charted `0 ms` for an
unreachable host is a misleading data point — it reads as "instant," not
"no data." Nullable figures force the consumer to handle the no-sample case
explicitly (§req:stats-success-criteria, §req:stats-user-stories — the
zero-reply story).

## Run summary reports the full statistic set §spec:stats-summary
*Status: implemented (dart_ping 10.0.0) — `PingSummary` gains a `RoundTripStats? stats` field (the run's round-trip figures) and a DERIVED `packetLoss` getter computed on read from `transmitted`/`received` (never stored, so it cannot drift; a run that transmitted nothing or received nothing reports 100% loss). `stats`/`packetLoss` participate in `copyWith`/`==`/`hashCode`/`toString`/`toMap`/`fromMap`. The round-trip figures come from the per-probe reply times accumulated during the run, so a zero-reply run carries the empty snapshot (figures absent, not fabricated zeros). Covered by network-free `dart test` cases in `dart_ping/test/{model_test,stats_event_test,serialization_test}.dart`.*

The terminal run-summary event reports the complete statistic set: the
round-trip `RoundTripStats` (§spec:stats-round-trip), a **packet-loss
percentage**, and the preserved `transmitted` / `received` / total `time` /
per-run `errors`.

- A completed run's summary shall report round-trip min / avg / max /
  stddev and jitter (via `RoundTripStats`) and a packet-loss percentage, in
  addition to `transmitted`, `received`, total `time` (where the platform
  reports it), and the per-run error list (§req:stats-success-criteria —
  full set; existing information preserved; §req:stats-priorities —
  must-have).
- The packet-loss percentage shall be a **derived view** of `transmitted`
  and `received`, computed on read, not an independently stored figure — so
  it can never drift from the counts and adds no redundant serialized field
  (§req:stats-success-criteria — loss consistent with counts;
  §req:stats-constraints — loss is a derived view).
- A zero-reply run shall report 100% loss with `received` zero and the
  round-trip figures absent (§spec:stats-round-trip;
  §req:stats-success-criteria — zero-reply honesty).

**Why loss is derived, not stored:** an independently stored loss number is
a second source of truth that a refactor or a serialization round-trip can
desynchronize from the counts. Computing `100 × (transmitted − received) /
transmitted` on read makes inconsistency unrepresentable
(§req:stats-quality-attributes — the loss-consistency criterion is met by
construction).

**Why keep `transmitted` / `received` / `time` / `errors`:** the redesign
must lose no existing result information (§req:stats-success-criteria).
Counts and the error list still come from where they do today — the native
summary line and the run's accumulated errors
(§spec:stream-lifecycle-robustness, §spec:ios-error-parity) — and total
`time` is reported where the platform provides it, unchanged.

## Live running statistics §spec:stats-live
*Status: implemented (dart_ping 10.0.0) — both `PingResponse` and `PingError` gain an additive nullable `RoundTripStats? stats` (null on events not from the live run path, so existing serialization/model round-trips are unchanged) participating in `copyWith`/`==`/`hashCode`/`toMap`/`fromMap`. `BasePing` attaches `_rttStats.snapshot()` to every emitted probe event — a response adds its own RTT THEN snapshots so the snapshot includes the current reply; an error snapshots the successful replies so far (errors never contribute to RTT figures) — reusing the same `RoundTripStatsAccumulator` as the terminal summary, so the last running snapshot equals `summary.stats`. The summary's `errors` list still stores the bare errors (their serialization is unchanged). Loss-so-far is derivable from `stats.sampleCount` (received-so-far) plus counted probe events (transmitted-so-far), consistent with the terminal `packetLoss`. Covered by network-free `dart test` cases.*

While a run is in progress, a consumer can observe the statistics evolve:
every probe event carries a **running `RoundTripStats` snapshot**
(min / avg / max / stddev / jitter / count so far), updated as each probe
arrives — not only once at the end.

- Each probe event (a response, and an error that carries probe
  information) shall carry a running `RoundTripStats` reflecting all
  successful replies seen so far in the run, so a consumer can display
  current conditions without waiting for the terminal summary
  (§req:stats-success-criteria — live stats observable;
  §req:stats-user-stories — the live-dashboard story; §req:stats-priorities
  — must-have).
- The running snapshot shall use the same definitions and the same
  computation as the final summary (§spec:stats-round-trip), so the last
  running snapshot of a run is consistent with the summary's figures
  (§req:stats-quality-attributes — consistency).
- A running packet-loss view shall be derivable during the run from the
  counts seen so far, consistent with the terminal loss
  (§req:stats-success-criteria — loss so far observable).

**Why attach the snapshot to each probe event rather than emit a separate
periodic stats event:** the natural cadence for "stats so far" is "whenever
a probe arrives," which is exactly when the figures change. Attaching the
snapshot to the probe event gives a deterministic, probe-driven update with
no extra event type and no timer, and lets a consumer read the current
figures from any event it is already handling. A separate periodic event
was rejected: it adds a second event kind and a non-deterministic timer
cadence for no behavior the attached snapshot does not already provide.

**Why this is the requirement that forces the sealed reshape:** carrying a
summary-so-far on every probe is impossible under the old `summary != null`
end-of-run signal (§spec:stats-event-model) — it is the concrete reason the
event model is redesigned rather than extended.

## Statistics computed uniformly across platforms §spec:stats-cross-platform
*Status: implemented on every platform incl. iOS (dart_ping 10.0.0 for the subprocess platforms; the iOS portion landed in Batch #63-4 — §spec:stats-ios — where `dart_ping_ios`'s `NativeEventStatsMapper` feeds the per-probe times into the SAME core `RoundTripStatsAccumulator`, so the figures are identical by construction) — `BasePing` feeds every successful probe's RTT into a single `RoundTripStatsAccumulator` and, at `_cleanup`, builds the terminal summary's `RoundTripStats` from that per-probe accumulation rather than from any native `ping` stats line (the native min/avg/max/stddev line is not parsed). Because the same accumulator code runs on Linux/Android, macOS, and Windows, every subprocess platform reports the identical figure set — including a computed standard deviation on Windows, whose native `ping` does not emit one. Covered by network-free `dart test` cases in `dart_ping/test/stats_event_test.dart` (per-probe → populated stats incl. non-null stddev, and the end-to-end BasePing path via a fake process).*

The round-trip statistics are computed once, at the Dart boundary, from the
**per-probe round-trip times the platform measured** — the same algorithm
on Linux/Android, macOS, Windows, and iOS. The native tools' own summary
*statistics* line (min/avg/max/stddev) is **not** the source of the
reported figures; the per-probe times that feed the computation are the
native measurements.

- Every platform shall report the complete statistic set — min / avg / max
  / stddev, jitter, and loss — including **stddev on Windows** (whose native
  `ping` omits it) and **every figure on iOS** (whose native engine emits
  no summary line at all) (§req:stats-success-criteria — same set on every
  platform; §req:stats-priorities — must-have).
- The statistics shall be derived from the per-probe round-trip times each
  platform already produces, normalized to one definition at the Dart
  boundary, so the figures carry identical semantics on every platform
  despite the native tools' differing (or absent) summary formats
  (§req:stats-quality-attributes — cross-platform consistency).
- `transmitted` and `received` shall continue to come from where they do
  today (the native summary line on the subprocess platforms,
  §spec:stream-lifecycle-robustness; the engine's counts on iOS,
  §spec:ios-error-parity); the successful-reply sample count the statistics
  summarize equals `received` by construction (§req:stats-success-criteria —
  loss consistent).

**Why compute rather than parse the native statistics line (resolving the
native-vs-computed open decision, §req:stats-open-decisions):** preferring
the native summary figures was the discovery-time starting position, but two
must-have criteria — the *same set on every platform* and *cross-platform
consistency* — override it, because the native figures are not the same
thing across platforms. Linux prints `mdev` (mean deviation), macOS prints a
true `stddev`, and Windows prints no deviation figure at all; "preferring
native" would therefore report three different quantities under one `stddev`
field and leave Windows blank. The native lines also vary in precision
(Windows is whole-milliseconds) and would add six more locale-sensitive
number formats to parse per platform — exactly the fragile text-parsing
surface §spec:ttl-exceeded-parse showed is error-prone. Computing from the
per-probe times — which *are* the native measurements — keeps native
fidelity where it is real (the individual RTTs) while guaranteeing one
definition, full precision (§spec:stats-precision), and the complete set
everywhere. The native statistics line is consequently left unparsed.

**Why this also makes the live view free:** because the figures are computed
incrementally from the per-probe times (§spec:stats-round-trip), the live
running snapshot (§spec:stats-live) and the final summary are the same
computation at different points — there is no separate "native summary" code
path the live view could diverge from.

**Tradeoff:** the reported stddev may differ slightly from the number a user
sees in their terminal on Linux (mdev) — but it will be a *correct,
consistent* standard deviation, documented as such (§spec:stats-round-trip),
which is more useful to a cross-platform consumer than faithfully echoing a
different statistic on each OS.

## Sub-millisecond precision preserved end-to-end §spec:stats-precision
*Status: implemented (Batch #63-3) — round-trip `Duration` values now serialize
at **microsecond** resolution end-to-end: `PingResponse.toMap`/`fromMap` and
`PingSummary.toMap`/`fromMap` encode `time` via `inMicroseconds` /
`Duration(microseconds:)` instead of the former whole-millisecond truncation,
and `RoundTripStats` already carried its figures (min/avg/max/stddev/jitter) in
microseconds from Batch #63-1, so the whole serialize→deserialize round trip
preserves sub-millisecond resolution. The map key stays `'time'`; only the
numeric scale changed, which the unreleased breaking 10.0.0 major absorbs.
Covered by network-free round-trip tests in
`dart_ping/test/serialization_test.dart` (§spec:stats-tests). The iOS
microseconds-over-channel half landed in Batch #63-4 (§spec:stats-ios): the
Swift engine now sends each probe's RTT (and the summary total) in microseconds
instead of rounding to whole milliseconds, and `ping_event_mapper_test.dart`
asserts a sub-millisecond round-trip value survives the native→event mapping.*

Round-trip times retain the resolution the platform provides —
sub-millisecond where the native tool reports it — through the in-memory
models, the statistics, and serialization. They are not truncated to whole
milliseconds on the way to the consumer.

- A per-probe round-trip `time` and the round-trip statistics derived from
  it shall retain sub-millisecond resolution end-to-end, including across
  `toMap` / `fromMap` (and JSON) serialization (§req:stats-success-criteria
  — precision preserved; §req:stats-quality-attributes — precision;
  §req:stats-priorities — high).
- Serialization of round-trip `Duration` values shall not truncate to whole
  milliseconds; the current `PingResponse.toMap` / `PingSummary.toMap`
  whole-millisecond truncation is corrected as part of this work
  (§req:stats-constraints — the `toMap` truncation is corrected;
  §req:stats-problem-statement — the raw material is lossy;
  §req:stats-open-decisions — serialization format).

**Why this matters and why now:** for a fast local link, round-trip times
are well under a millisecond, so a whole-millisecond representation rounds
stddev and jitter toward zero and makes them meaningless — the precise
failure the reporter's use case (a latency dashboard) would hit. The values
already exist sub-millisecond in memory (the subprocess parsers capture
fractional milliseconds; the iOS engine measures microseconds,
§spec:stats-ios); only the serialization step discards it. Fixing the
encoding to carry microsecond resolution is a small, contained change that
the breaking major (§spec:stats-event-model) lets us make to the wire format
without a separate compatibility break. The exact on-the-wire encoding is an
implementation choice; the normative contract is only that the round-trip
resolution survives a serialization round-trip.

## iOS statistics parity §spec:stats-ios
*Status: implemented (Batch #63-4) — the Dart bridge maps native results onto the sealed `PingEvent`s (`ping_event_mapper.dart`: `mapNativeEvent` returns a bare variant; a timed-out / TTL-exceeded probe is a single `PingError` carrying its own `seq`/`ip`, matching the core parser) and computes `RoundTripStats` (incl. population stddev) + the live running snapshot via a `NativeEventStatsMapper` that **reuses the core `RoundTripStatsAccumulator`** — the same code and math as `BasePing` — so the iOS live snapshot and terminal summary match the subprocess platforms by construction (no parallel Swift computation). `DartPingIOS.stream` is now `Stream<PingEvent>` and stamps every event with the running snapshot. The native Swift engine surfaces each probe's RTT (and the summary total) at **microsecond** resolution over the channel (the `(rttMicros+500)/1000` whole-ms rounding is removed; the engine still streams only raw per-probe data and computes no aggregates). Dart-side covered by network-free `dart_ping_ios/test/ping_event_mapper_test.dart` (sealed-event mapping incl. the full ErrorType set + microsecond/sub-ms precision, and the `NativeEventStatsMapper` seam asserting per-event live snapshots and the terminal summary equal the core `RoundTripStats.fromSamples`, plus the zero-reply 100%-loss case); green under `flutter test` on the Linux host. The Swift microsecond change is not compilable on the Linux CI host — hand-verified; macOS CI (`xcodebuild test`) compiles/runs it. Live ICMP round-trips remain the manual example-app acceptance path.*

iOS reports the same statistic set as every other platform, computed by the
**same shared Dart code**. The native Swift engine has no summary-statistics
line; it streams per-probe round-trip times, and the Dart bridge computes
the `RoundTripStats` from them exactly as the core package does.

- iOS shall report the complete statistic set — min / avg / max / stddev,
  jitter, and loss — and live running statistics during a run, on a par with
  the subprocess platforms (§req:stats-success-criteria — same set on every
  platform, including iOS; §req:stats-quality-attributes — consistency).
- The statistics shall be computed at the Dart boundary by the **same
  computation** the core `dart_ping` package uses (§spec:stats-round-trip),
  reused by `dart_ping_ios`, so iOS parity holds by construction rather than
  by a parallel Swift implementation (§req:stats-quality-attributes —
  consistency, testability).
- The native engine shall surface per-probe round-trip times at
  **microsecond resolution** (it already measures microseconds before
  rounding), so iOS retains the sub-millisecond precision §spec:stats-precision
  requires; the engine does not compute min / avg / max / stddev itself
  (§req:stats-open-decisions — iOS surfacing mechanism;
  §req:stats-success-criteria — precision).

**Why compute in shared Dart rather than in Swift (resolving the iOS
surfacing open decision, §req:stats-open-decisions):** the native engine
already streams each probe's `seq` / `ttl` / `time` / `ip` and accumulates
`transmitted` / `received` / `errors` (§spec:ios-ping-behavior,
§spec:ios-error-parity); the only data the stats need is the per-probe
round-trip time, which it already has. Computing the aggregate figures in
Swift would duplicate the math on the far side of the method channel and
risk it drifting from the core package's definitions — the cross-platform
inconsistency this area exists to remove. Reusing the one Dart
`RoundTripStats` computation makes iOS identical to the other platforms for
free, and keeps the native↔Dart channel carrying only raw per-probe data.

**Why send microseconds over the channel:** the engine currently rounds RTT
to whole milliseconds before sending (the only iOS-side precision loss), so
on fast links its stddev/jitter would collapse to zero. Surfacing the
microseconds it already measures is the iOS half of the end-to-end precision
guarantee (§spec:stats-precision). The channel payload is an implementation
detail (§spec:ios-ping-behavior); only the resulting `Duration` resolution
is normative.

## Statistics behavior tests §spec:stats-tests
*Status: in progress — the round-trip computations, packet-loss derivation /
zero-reply case, and the sealed-event contract landed with the model redesign
(Batch #63-1, `dart_ping/test/stats_event_test.dart`). The **sub-millisecond
precision round-trip** bullet is covered (Batch #63-3):
`dart_ping/test/serialization_test.dart` serializes and deserializes
sub-millisecond `PingResponse.time` and a `RoundTripStats` derived from
sub-millisecond samples (carried on a `PingSummary`) and asserts every
round-trip `Duration` survives to the microsecond (§spec:stats-precision). The
**live-consistency** coverage landed (Batch #63-2):
`dart_ping/test/live_stats_test.dart` asserts every probe event
(`PingResponse` and per-probe `PingError`) carries a non-null running
`RoundTripStats` snapshot; the running snapshot tracks the same computation as
the summary step by step (the i-th response equals
`RoundTripStats.fromSamples([rtt_0..rtt_i])`, and a timeout carries the
snapshot of the successful replies seen so far); the last running snapshot
equals the terminal `summary.stats` for a run ending in a reply, a run whose
last probe is a timeout, and the zero-reply run; and loss-so-far derived from
probe-event count (transmitted) and `stats.sampleCount` (received) matches the
terminal `summary.packetLoss` — all offline via the `FakeProcess`/`TestPing`
harness. The iOS native-result → event/stats mapping tests landed in Batch
#63-4 (`dart_ping_ios/test/ping_event_mapper_test.dart`): over the
`NativeEventStatsMapper` seam they assert iOS produces the same statistic set
(including population stddev) and the same per-event live snapshots from
per-probe inputs as the core `RoundTripStats.fromSamples`, plus the zero-reply
100%-loss case (§spec:stats-ios).*

The statistics and the event contract are covered by automated tests that
run under `dart test` / `flutter test` without a live network.

- The round-trip computations (min / avg / max / population stddev /
  jitter) shall be covered by tests over representative per-probe inputs
  with known expected values, including the single-sample and zero-reply
  cases (§req:stats-success-criteria — automated tests, zero-reply;
  §req:stats-priorities — high; §spec:stats-round-trip).
- The packet-loss derivation and its consistency with `transmitted` /
  `received`, and the zero-reply 100%-loss / absent-figures case, shall be
  covered (§req:stats-success-criteria; §spec:stats-summary).
- The sealed event contract shall be covered: a test shall confirm the
  terminal summary event is distinguishable by type and is the final event,
  and that probe-response and probe-error events are distinguishable
  (§req:stats-success-criteria — terminal event identifiable;
  §spec:stats-event-model).
- The sub-millisecond precision round-trip through serialization shall be
  covered by a test that serializes and deserializes a sub-millisecond
  round-trip value and asserts no precision is lost
  (§req:stats-success-criteria — precision; §spec:stats-precision).
- The iOS mapping shall be covered by Dart-side tests over the
  native-result → event/stats seam, asserting iOS produces the same
  statistic set (including stddev) from per-probe inputs as the core package
  (§req:stats-success-criteria — iOS parity; §spec:stats-ios,
  §spec:ios-tests).

**Why offline seams only:** the statistic math is pure (per-probe times in →
figures out) and the event contract is pure (events in → type
discrimination out), so both are fully testable without a live network — the
deterministic-seam principle the suite already follows (§spec:ci,
§spec:coverage-expansion). Live ICMP round-trips remain the manual
acceptance path; they are not where the statistics logic is verified.

---

# NAT64 / IPv6-only IP-literal reachability

Solution-space design for issue #52 (`§req:nat64-*`): make pinging a bare
IPv4 literal **succeed** on an IPv6-only cellular network, where it fails
today, by reaching the target through the platform's own NAT64 address
synthesis. The work is primarily in `dart_ping_ios` (the native Swift
engine's resolve/send path) plus one new option on the shared `Ping`
factory; it changes no result shape and no `IpVersion` semantics.

The problem (from §req:nat64-problem-statement): on iOS over mobile data,
pinging an IPv4 literal (e.g. `13.35.27.1`) fails outright, while the same
literal works over Wi-Fi and a *hostname* works on the same cellular
connection. The carrier runs an IPv6-only access network with NAT64/DNS64
(464XLAT): a hostname is resolved by DNS64 to a synthesized IPv6 (NAT64)
address that routes to the IPv4 host, but a raw IPv4 literal is handed to
the stack with no synthesis and has no native IPv4 route. The tell that
this is fixable, not a carrier wall: third-party ping apps and Apple's
updated `SimplePing` reach the same literal on the same network once they
feed it through the system resolver, which returns a synthesized address.

This **revises the scope boundary of #69** (`§spec:address-family-error-honesty`,
"scope boundary — honesty, not new capability"). #69 made the IPv4-literal
failure's *error* honest (a typed `noRoute` instead of a phantom
`unknownHost`) but treated the literal as having "legitimately no route."
#52's evidence contradicts that premise — the route can be obtained via
synthesis — so the deliverable here is the capability #69 declined to add:
the ping actually works. Where synthesis cannot help, #69's honest typed
error still stands; #52 sits **in front of** #69, not instead of it.

**Why lean on the platform's synthesis rather than build our own:** the
library does no DNS of its own (§req:nat64-constraints,
§req:ipfamily-quality-attributes — thinness). The OS resolver already
performs DNS64/NAT64 synthesis when not told to pin a family; Apple
documents exactly this path in *"Supporting IPv6 DNS64/NAT64 Networks"*.
The fix is therefore to stop suppressing synthesis on the literal path, not
to add a NAT layer — keeping the engine thin and faithful to native
behavior. A hand-rolled DNS64/NAT64 resolver was rejected: it would
duplicate the platform stack, drift from carrier behavior, and violate the
no-DNS constraint.

## IPv4 literals reach IPv6-only networks via NAT64 synthesis §spec:nat64-literal-synthesis
*Status: implemented (Batch #52-2) — the iOS Swift engine un-pins the resolve for
the narrow IPv4-literal + synthesis-enabled + `IpVersion.ipv4` case only: it
calls `getaddrinfo` with `AF_UNSPEC` and no `AI_NUMERICHOST` (gated by the pure
`PingEngine.shouldSynthesize(family:nat64Synthesis:host:)`, which is true iff
`nat64Synthesis && family == .v4 && isIPv4Literal(host)`), so the platform may
return a synthesized NAT64 address on an IPv6-only network (and the plain IPv4
address on Wi-Fi / dual-stack); it then sends ICMP/ICMPv6 to whichever TRANSPORT
family the resolver returns while the caller-selected `IpVersion` is unchanged.
When the resolver returns BOTH a synthesized IPv6 address and the original IPv4
literal, the engine PREFERS the IPv6 (NAT64) address rather than committing to
whichever entry `getaddrinfo` sorted first — the bare IPv4 literal has no route
on an IPv6-only network, so first-entry selection could silently defeat the fix;
this routable-family choice lives in the pure `PingEngine.synthesizedTransport(hasIPv4:hasIPv6:)`.
Every other path keeps #69's byte-for-byte family-pinned resolve. The synthesis
decision and the address-selection policy are offline-covered by the network-free
`shouldSynthesize` / `isIPv4Literal` / `synthesizedTransport` XCTest cases in the
example's `RunnerTests` (iOS + macOS targets); the Swift change is not compilable
on the Linux CI host (hand-verified; macOS CI `xcodebuild test` compiles/runs it).
The live IPv6-only-cellular reachability leg is an on-device acceptance step
(§spec:nat64-tests).*

On iOS, pinging an IPv4 literal on an IPv6-only (NAT64/DNS64) cellular
network produces the **same observable result as pinging it over Wi-Fi** —
replies with round-trip times and a normal summary — instead of failing
outright. The library reaches the target through a platform-synthesized
NAT64 address; the caller's selected family and the result shape are
unchanged.

- When NAT64 synthesis is enabled (§spec:nat64-option), the selected family
  is `IpVersion.ipv4`, and the target is an **IPv4 literal**, the iOS engine
  shall obtain the destination through the system resolver in a way that
  lets the platform return a **synthesized NAT64 address** on an IPv6-only
  network (and the plain IPv4 address on a dual-stack / Wi-Fi network), and
  shall send ICMP/ICMPv6 echo probes to whichever address family the
  resolver returns (§req:nat64-success-criteria — the literal pings
  successfully; §req:nat64-problem-statement).
- On a network where the IPv4 literal fails today, the consumer shall
  receive responses, round-trip times, and a run summary equivalent to the
  Wi-Fi result and to what third-party ping tools achieve on the same device
  (§req:nat64-success-criteria — reachability parity;
  §req:nat64-quality-attributes — reachability parity).
- The caller's selected `IpVersion.ipv4` and the IPv4 literal it pinged
  shall be unchanged by synthesis: that the host is reached via a synthesized
  IPv6/NAT64 address underneath is an implementation detail and shall not
  alter the result shape, the reported target, or the selected family
  (§req:nat64-success-criteria — user-facing family unchanged;
  §req:nat64-constraints — family selection unchanged).
- A hostname ping (including a DNS64-synthesized one), a ping over Wi-Fi or
  a dual-stack network, and an IPv4 literal that already routes shall behave
  identically with synthesis enabled — synthesis changes only the
  previously-unreachable IPv6-only-literal case
  (§req:nat64-success-criteria — regression guard; §spec:ios-ping-behavior).

**Why this scopes to an IPv4 literal under `IpVersion.ipv4`:** the reported
failure is specific to a bare IPv4 literal — hostnames already get DNS64
synthesis from the system resolver, an IPv6 literal needs none, and an
`IpVersion.ipv6` selection is unaffected. Synthesis is therefore engaged
only on the one path that is broken, leaving every working path untouched
(§req:nat64-constraints — fallback ordering).

**Why the engine sends to the resolver's returned family, relaxing #69's
"never the other family" rule here:** #69 pins `ai_family` so a *hostname*
never silently resolves to a family the caller did not select
(§spec:address-family-error-honesty). For an IPv4 *literal* with synthesis
enabled, reaching it via a synthesized IPv6/NAT64 address is not a silent
family switch — it is NAT64 *transport* to the same IPv4 destination the
caller named, and it is exactly what every other ping tool on the device
does. The relaxation is deliberately narrow: IPv4 literal only, synthesis
enabled only, and it changes the transport address, not the caller-selected
`IpVersion`. Pinning the family on the literal path (the #69 behavior) is
what suppresses synthesis and causes the failure; the opt-out
(§spec:nat64-option) restores that pinned, raw-pass-through behavior for
callers who want it. This narrow relaxation does not reopen #69's bug,
whose signature was a *hostname* mislabeled and a routing failure reported
as `unknownHost` — both still handled honestly here
(§spec:nat64-error-fallback).

**Why iOS is the primary (and only confirmed) target:** the failure is
reported and reproducible on iOS over cellular, and Apple documents the
synthesis path the engine owns. On the subprocess platforms the option is a
documented no-op (§spec:nat64-option) — their native `ping` binaries do
their own resolution, and Android's NAT64 handling (464XLAT/clatd) operates
at the network layer below the binary. Extending active synthesis beyond
iOS is a nice-to-have deferred to those platforms' own evidence
(§req:nat64-priorities — nice-to-have; §req:nat64-open-decisions — platform
reach).

## NAT64 synthesis is an explicit, default-on option §spec:nat64-option
*Status: implemented (Batch #52-1) — the `Ping` factory accepts a named
`bool nat64Synthesis` defaulting to enabled, threaded through `BasePing` (a
stored field) and sent to the iOS bridge over the method channel in the `start`
invocation alongside `ipVersion`. On the subprocess platforms (Linux/Android,
macOS, Windows) it is a documented no-op: the field is carried but unread, so
`params`/`command` stay byte-for-byte identical and the option never raises an
error, keeping a cross-platform call identical. dartdoc on the factory
parameter describes what it does, the default, which platform synthesizes (iOS)
vs. treats it as a no-op, and that disabling restores raw pass-through;
CHANGELOG (dart_ping 10.0.0 / dart_ping_ios 6.0.0) and the root README document
it. Covered by network-free tests (`dart_ping/test/nat64_option_test.dart` —
presence/default/threading plus the `params`/`command` no-op guard — and the
`dart_ping_ios` bridge `start`-argument assertions). The native engine acting on
the flag (actual NAT64 synthesis) lands in Batch #52-2,
§spec:nat64-literal-synthesis / §spec:nat64-error-fallback.*

NAT64 / IPv6-only literal handling is controlled by a single named option
on the `Ping` factory that is **enabled by default**, so an affected user's
existing call starts working with no code change, and a caller can disable
it to restore the prior raw-pass-through behavior.

- The `Ping` factory shall accept a named, documented boolean option (e.g.
  `nat64Synthesis`) that defaults to **enabled**, threaded to the iOS engine
  the way `ipVersion` and `interface` already are
  (§req:nat64-success-criteria — controlled by an explicit, default-on
  option; §req:nat64-priorities — must-have).
- With the option at its default, an affected caller's existing
  IPv4-literal ping shall begin succeeding on an IPv6-only network with **no
  source change**; with the option disabled, the engine shall use the prior
  raw behavior (the family-pinned resolve of §spec:address-family-error-honesty,
  no synthesis), reproducing the pre-#52 outcome
  (§req:nat64-success-criteria — opt-out restores prior behavior;
  §req:nat64-user-stories).
- The option shall be present with the same name and default on every
  platform; where a platform cannot synthesize, it shall be a documented
  **no-op** rather than an error, so the cross-platform call stays identical
  (§req:nat64-success-criteria — consistent presence and default;
  §req:nat64-quality-attributes — cross-platform consistency;
  §req:nat64-constraints — platform-dependent, gated by an explicit option).
- The dartdoc shall describe what the option does, that it defaults to
  enabled, which platforms actively synthesize (iOS) versus treat it as a
  no-op, and that disabling it restores raw pass-through
  (§req:nat64-priorities — high, documentation;
  §req:nat64-quality-attributes — documented, not surprising).

**Why default-on rather than opt-in:** the affected users cannot reproduce
the failure on their own Wi-Fi or in the simulator, and the fix should reach
their existing code without their having to discover and set a flag
(§req:nat64-problem-statement — expensive to diagnose;
§req:nat64-priorities — must-have). The behavior also matches user
expectation — every other ping tool on the device already reaches the
literal — so "works by default" is the least surprising default. The opt-out
exists for callers who deliberately want raw pass-through (e.g. to observe
the un-synthesized failure), preserving backward compatibility as a choice
rather than the default (§req:nat64-quality-attributes — backward-compatible,
default-on).

**Why one boolean rather than a richer policy object:** the only decision a
caller makes is "let the platform synthesize, or pass the literal raw," a
binary choice; the per-platform capability difference is fixed by the
platform, not configured. A boolean keeps the surface minimal and the
default obvious (§req:nat64-constraints — option shape). A multi-valued
"NAT64 mode" was rejected for the same reason `IpVersion` rejected an
"auto/dual-stack" value (§spec:ipv6-address-family-selector): named modes
imply behaviors the library does not offer.

## Synthesis precedes the honest #69 error, and yields to it §spec:nat64-error-fallback
*Status: implemented (Batch #52-2) — when synthesis cannot produce a routable
address for the IPv4 literal, the engine surfaces #69's honest typed error:
an address-family / no-route condition becomes `ErrorType.noRoute`, never a
phantom `unknownHost` and never a silent hang, and `unknownHost` stays reserved
for a genuine name miss. With synthesis disabled, or for a genuinely-unreachable
target, the engine reproduces #69 exactly (the family-pinned resolve), and the
synchronous literal-vs-family `ArgumentError` is untouched (it fires only on a
contradicting literal, never on the matching IPv4-literal-under-`IpVersion.ipv4`
case synthesis operates within). The honest classification is covered by the
network-free `errorKind(forGetaddrinfoStatus:)` / `errorKind(forSendErrno:)`
XCTest cases in `RunnerTests` (`EAI_NODATA`/`EAI_ADDRFAMILY`/`EAI_FAMILY` ->
`.noRoute`, `EAI_NONAME` -> `.unknownHost`;
`ENETUNREACH`/`EHOSTUNREACH`/`EAFNOSUPPORT`/`EADDRNOTAVAIL` -> `.noRoute`), and
the Dart mapping seam by `dart_ping_ios/test/ping_event_mapper_test.dart`
(native `No Route` -> `ErrorType.noRoute`, `Unknown Host` -> `ErrorType.unknownHost`,
both honest typed errors, never a phantom or null). The Swift classification is
not compilable on the Linux CI host (hand-verified; macOS CI runs it).*

Synthesis is attempted first; when it cannot produce a routable address —
synthesis unsupported, no synthesized address available, or a genuine
no-route — the consumer receives #69's honest typed error, never a phantom
`unknownHost` and never a silent hang. #69's error honesty and its
literal-vs-family `ArgumentError` are preserved exactly.

- When the option is enabled but the platform returns no synthesized or
  otherwise routable address for the IPv4 literal, the engine shall surface
  the honest typed error from #69 — `ErrorType.noRoute` for an
  address-family / no-route condition, `unknownHost` only for a genuine
  name-resolution failure — and shall **never** report a phantom
  `unknownHost` for a routing failure nor hang/time out silently
  (§req:nat64-success-criteria — error stays honest when synthesis cannot
  help; §spec:address-family-error-honesty).
- When the option is disabled, or the target is genuinely unreachable, the
  engine shall reproduce #69's honest typed errors exactly, including the
  reserved meaning of `unknownHost` (§req:nat64-success-criteria — no
  regression to #69 error honesty; §spec:address-family-error-honesty).
- Synthesis shall not disturb the synchronous literal-vs-family
  `ArgumentError`: an `IpVersion.ipv4` selection with an IPv4 literal matches
  and is never rejected (synthesis operates within this matched case), and a
  mismatched literal (e.g. `IpVersion.ipv4` with an IPv6 literal) still
  throws before any stream starts, unchanged by this option
  (§req:nat64-constraints — do not regress #69;
  §spec:address-family-mismatch-validation).
- The user-facing `IpVersion` selection shall be unchanged by the fallback
  path as well: whether synthesis succeeds or yields to the honest error, the
  caller's selected family is the one validated and reported
  (§req:nat64-constraints — family selection unchanged;
  §req:nat64-open-decisions — interaction with the `IpVersion` selector).

**Why synthesis-first, honest-error-second:** the requirement is to make the
ping *work* where it can while keeping the *error honest* where it cannot
(§req:nat64-success-criteria). Attempting synthesis first converts the
previously-unreachable literal into a reachable one on a NAT64 network;
falling back to #69's typed error on genuine failure means the consumer
never loses the diagnostic honesty #69 established. The two are complementary
layers, not alternatives — #52 adds capability in front of #69's honesty
without removing it (§spec:address-family-error-honesty — scope boundary,
now revised).

**Why the `ArgumentError` is untouched:** that guard fires only on a
literal whose family *contradicts* the selection
(§spec:address-family-mismatch-validation); #52's case is a *matching*
IPv4-literal-under-`IpVersion.ipv4`, which the guard lets through. Synthesis
therefore operates entirely inside the already-valid case and has no reason
to alter the guard — confirming this is a design invariant, not a new code
path (§req:nat64-open-decisions — interaction with #69 validation).

## NAT64 reachability tests §spec:nat64-tests
*Status: implemented offline (Batches #52-1, #52-2); live leg on-device only —
the option-presence / default-enabled / threading bullet is covered offline
(Batch #52-1): `dart_ping/test/nat64_option_test.dart` asserts the option
defaults to enabled on every subprocess class, threads the supplied value, and is
an inert no-op (`params`/`command` byte-for-byte unchanged), and
`dart_ping_ios/test/dart_ping_ios_test.dart` asserts the bridge `start` arguments
carry `nat64Synthesis` (true by default, false when disabled, and forwarded
verbatim for the IPv4-literal + `IpVersion.ipv4` argument shape). That Dart test
covers only the bridge's verbatim threading — the synthesis DECISION itself is a
native concern and is covered by `RunnerTests` below, not by the bridge test. The
synthesis decision, the routable-address selection, and the fallback-to-honest-
error mapping land in Batch #52-2: the network-free `shouldSynthesize` /
`isIPv4Literal` / `synthesizedTransport` (the prefer-IPv6-over-a-co-listed-IPv4-
literal selection policy) and the `errorKind(forGetaddrinfoStatus:)` /
`errorKind(forSendErrno:)` XCTest cases in the example's `RunnerTests` (iOS +
macOS targets) pin the un-pinned-vs-pinned resolve decision, the
synthesized-family choice, and the honest `.noRoute` / `.unknownHost`
classification, and
`dart_ping_ios/test/ping_event_mapper_test.dart` pins the Dart mapping seam
(native `No Route` / `Unknown Host` -> the honest typed `PingError`, never a
phantom or null) plus the synthesis-on regression guards (a normal reply still
maps to an intact `PingResponse` with its stats snapshot). The Dart seams run
green under `flutter test` on the Linux CI host; the Swift seams are hand-verified
(not compilable on Linux; macOS CI `xcodebuild test` compiles/runs them). The
remaining manual step is the live leg — an IPv4 literal actually pinging through
on an IPv6-only cellular network — an on-device acceptance step, not a CI gate
(§spec:nat64-literal-synthesis, §spec:nat64-error-fallback).*

The option's on/off behavior and the synthesis-vs-honest-error decision are
covered by automated tests that need no live IPv6-only cellular network; the
live end-to-end leg is hand- / on-device-verified, as with #69.

- The option's presence, default-enabled value, and threading to the engine
  shall be covered by network-free tests over pure input (the constructed
  `Ping` / bridge arguments), including that the default is enabled and that
  disabling it selects the raw path
  (§req:nat64-success-criteria — automated tests offline;
  §req:nat64-priorities — high; §spec:nat64-option).
- The synthesis decision and the fallback-to-honest-error mapping shall be
  covered at the iOS resolve/send seam: with synthesis on, an IPv4 literal
  drives the un-pinned resolve path; with it off, the family-pinned path;
  and a resolver outcome that yields no routable address maps to the honest
  `noRoute` / `unknownHost` error rather than a phantom or a hang — all
  without a live process (§req:nat64-success-criteria — synthesis decision
  and on/off verifiable offline; §spec:nat64-literal-synthesis,
  §spec:nat64-error-fallback).
- The live leg — an IPv4 literal actually pinging through on an IPv6-only
  cellular network — shall be an on-device acceptance step, not a CI gate
  (§req:nat64-success-criteria — live leg on-device-verified;
  §req:nat64-constraints — not reproducible in CI).

**Why offline seams plus an on-device leg:** a live IPv6-only cellular
network is unavailable to hosted runners and not reproducible in the
simulator (§req:nat64-constraints — not reproducible in CI), exactly the
constraint #69 faced (§spec:address-family-error-tests). The testable
surface is the pure logic — option default and threading (input in →
arguments out) and the resolve-path / error-mapping decision (selection +
resolver outcome in → synthesized-send or typed-error out) — while the
end-to-end reachability is verified by hand on an affected device, mirroring
the suite's established deterministic-seam principle (§spec:ci,
§spec:ios-tests).

---

# Windows interface-listing round-trip contract

Solution-space design for issue #85 (`§req:windows-roundtrip-*`). A
clarification of the interface work (#72, `§spec:interface-selection` …
`§spec:interface-listing`), not a new capability. The listing helper
(§spec:interface-listing) promises that what it returns "feeds straight back
into a `Ping`'s `interface` value." A round-trip test encoded a *stronger*
reading of that promise than the package ever offered — that *every listed
interface's name* constructs a `Ping` without throwing on *every* platform —
which the package contradicts on Windows by design (§spec:interface-platform-rejection:
a bare name is rejected because Windows `ping` binds only by source address).

The contradiction was invisible while the round-trip ran only on hosts whose
`NetworkInterface.list()` happened to report addresses, and while the gate
ran the core suite only where the assumption held. Once the cross-OS matrix
(§spec:ci) ran the core suite on a real Windows runner — which reports a
named NIC (e.g. `"Ethernet 3"`) — the test fed that name into a Windows
`Ping`, the constructor correctly threw `UnimplementedError`, and the
Windows check went red (`195 passed, 1 failed`). The defect is in the test's
*expectation*, not in Windows behavior: Windows was doing exactly what
§spec:interface-platform-rejection specifies. This area makes the
listing↔selection round-trip contract honest per platform and proves it on a
real Windows host, with no change to any platform's runtime behavior.

## Per-platform round-trip honesty §spec:windows-roundtrip-contract
*Status: implemented (Batch #85-1) — the round-trip test `dart_ping/test/interface_listing_test.dart` ("each interface has the right shape and round-trips into Ping") now branches the listed-**name** expectation on the platform's binding ability (`Platform.isWindows`): a name round-trips (`returnsNormally`) on name-binding platforms (Linux/Android, macOS) and is expected to throw the catchable `UnimplementedError` on Windows (which `PingWindows` raises at construction), while a listed source **address** round-trips (`returnsNormally`) on every desktop platform. The expectation no longer depends on which names/addresses a runner reports, so it is deterministic on any host and the `core (windows-latest)` job goes green alongside Linux and macOS. The listing helper's dartdoc, the README "Selecting a network interface" section, and the CHANGELOG note that on Windows a listed interface is passed back as its source address, not its name. No runtime, command, stream, or public-API change on any platform. Covered by network-free `dart test` (the full core suite passes `-x live`, 196 tests).*

The handle a developer carries from `listNetworkInterfaces()` back into a
`Ping(interface: …)` round-trips per the platform's actual binding ability:
a listed interface's **source address** constructs a `Ping` without throwing
on every supported desktop platform; a listed interface's **name** does so
only where the OS `ping` binds by name (Linux/Android, macOS). On Windows a
listed **name** is rejected with the catchable error already specified, and a
listed **address** is accepted. Nothing about Windows runtime behavior
changes — only the contract's wording and the test that asserts it.

- A listed interface's source **address** shall round-trip — feed back into
  `Ping('…', interface: addr)` and construct without throwing — on **every**
  supported desktop platform (Linux/Android, macOS, Windows), because every
  platform's `ping` can bind a source address (§req:windows-roundtrip-success-criteria
  — round-trip honest per platform; §spec:interface-selection).
- A listed interface's **name** shall round-trip the same way **only** on the
  platforms whose `ping` binds by name (Linux/Android, macOS). On **Windows**,
  passing a listed name shall be rejected by the same explicit, catchable
  `UnimplementedError` specified in §spec:interface-platform-rejection —
  Windows `ping` binds only by source address — never a silent default-route
  ping (§req:windows-roundtrip-success-criteria — round-trip honest per
  platform; §req:windows-roundtrip-constraints — Windows keeps rejecting bare
  names).
- Windows runtime behavior shall be unchanged: source-address selection still
  binds, a bare name is still rejected loudly, and no other platform's
  command, stream behavior, or public API changes. Only the contract and the
  test expectation move (§req:windows-roundtrip-success-criteria — Windows
  runtime unchanged; §req:windows-roundtrip-constraints — no new public API,
  no behavior change; §spec:public-api-stability).
- The round-trip shall be verified by automated tests that pass on a real
  Windows host and whose pass/fail does **not** depend on which interface
  names or addresses a particular runner reports. The expectation branches on
  the platform's binding ability (name-binding vs. address-only), not on the
  contents of the host's NIC list, so it is deterministic on any runner
  (§req:windows-roundtrip-success-criteria — deterministic across runners;
  §req:windows-roundtrip-quality-attributes — determinism, testability).
- With the expectation corrected, the `core (windows-latest)` job shall pass,
  so the cross-OS gate (§spec:ci) is green on Linux, Windows, and macOS
  together and merges are no longer blocked by a test asserting behavior the
  package intentionally does not have (§req:windows-roundtrip-success-criteria
  — Windows core CI check passes; §req:windows-roundtrip-user-stories —
  maintainer).
- As a nice-to-have, the listing helper's documentation shall note that on
  Windows a listed interface is passed back as its **source address**, not
  its name, so the per-platform contract is discoverable at the point of use
  (§req:windows-roundtrip-priorities — nice-to-have; §spec:interface-listing).

**Why correct the expectation rather than make Windows accept names:** the
package deliberately rejects a bare interface name on Windows
(§spec:interface-platform-rejection) because the OS `ping` binds only by
source address; silently approximating it would defeat the diagnostic the
interface feature exists for (§spec:interface-selection). The test, not the
package, was wrong — it asserted a guarantee §spec:interface-listing never
made (the helper's normative contract is only that what it returns "can be
fed back into `interface`," which the **address** satisfies everywhere, not
that the **name** binds everywhere). A red required check that flags correct
behavior trains maintainers to distrust the gate (§spec:ci — a required
check must be reliable), so the honest fix is to align the expectation with
the specified per-platform behavior.

**Why the source address is the universal round-trip handle:** every
platform's `ping` can bind a source address, while only some bind by name;
choosing the address as the cross-platform handle is the one form that makes
"pass one back into a `Ping`" true everywhere without per-platform branching
at the call site (§req:windows-roundtrip-constraints — decided in discovery).

**Why branch the test on binding ability, not on the host's NIC list:** the
original failure was runner-dependent — it surfaced only because the Windows
runner reported a named NIC. Keying the expectation off the platform's
documented binding ability (does this `ping` bind by name?) rather than off
whatever names/addresses `NetworkInterface.list()` returns makes the check
reproducible on any runner and prevents the same contradiction from silently
returning (§req:windows-roundtrip-quality-attributes — determinism,
testability).

**Alternative rejected — resolve a Windows interface name to its source
address so names round-trip everywhere:** explicitly out of scope
(§req:windows-roundtrip-constraints). It would add a per-platform
name→address resolution surface — the kind of OS-specific text/lookup logic
§spec:interface-listing deliberately avoided by building on `dart:io` — to
paper over a difference the contract can simply state honestly. The cheaper,
truthful design is to document that Windows round-trips by address.

**Scope boundary:** this refines the interface contract and its tests only.
The separate Windows IPv6 gap (#71) is not in scope, and no change is made to
Linux/Android or macOS behavior. Traceability: surfaced by #85 (the CI work
that ran the core suite on a Windows host), relating to the cross-OS matrix
(#77, §spec:ci) and interface selection (#72,
§spec:interface-selection / §spec:interface-platform-rejection /
§spec:interface-listing).

---

# Package consolidation — one `dart_ping` with FFI-backed iOS

A packaging and integration-mechanism change folded into the same
unreleased `dart_ping` 10.0.0 train. It resolves
[#28](https://github.com/point-source/dart_ping/issues/28) (collapse the two
packages into one without losing pure-Dart support) and
[#48](https://github.com/point-source/dart_ping/issues/48) (iOS ping fails
inside a secondary isolate), which share one root cause: the iOS path talks
Dart↔Swift over Flutter **platform channels**, which both forces a separate
Flutter plugin package (the reason `dart_ping_ios` exists) and routes every
message through the root-isolate binary messenger (the reason ping throws in a
background isolate).

The enabling change is external: Dart's **build hooks** and **code assets**
became stable in Dart 3.10 / Flutter 3.38 (November 2025). A pure-Dart package
can now compile and bundle native code and call it over `dart:ffi`, with the
native build triggered by the build target — and a single package resolves and
runs under both the Dart and the Flutter toolchains, with no second
publication. This removes the dependency the #28 thread was blocked on and, by
replacing channels with FFI, removes the root-isolate coupling behind #48 at
the same time.

These sections reuse the iOS SPM migration's native engine
(§spec:swift-icmp-engine) and
preserve every observable iOS behavior it specifies
(§spec:ios-ping-behavior, §spec:ios-error-parity, §spec:ios-ttl,
§spec:stats-ios). What changes is the *binding* (platform channels → FFI) and
the *package boundary* (two packages → one). Where this contradicts the prior
iOS packaging — the separate federated plugin of §spec:spm-distribution, the
channel wiring described in §spec:ios-ping-behavior, the `register()` entry
point of §spec:public-api-stability — these sections supersede it. Those prior
sections remain the accurate record of the 9.x / pre-consolidation iOS
implementation that shipped over channels.

## One `dart_ping` package provides iOS §spec:single-package-ios
*Status: not started*

A Flutter app targeting iOS adds **only `dart_ping`** — no `dart_ping_ios`
dependency and no registration call — and gets working iOS ping. iOS support
lives in `dart_ping` and is dispatched by platform inside the package, exactly
as the Linux / macOS / Windows subprocess paths already are
(§spec:public-api-stability).

- When a Flutter iOS app depends only on `dart_ping` (SPM enabled, no
  CocoaPods `Podfile`), constructs a `Ping`, and listens to its `stream`, the
  system shall produce correct per-probe `PingResponse`s and a terminal
  `PingSummary` — the same observable behavior as every other platform
  (§req:consolidation-success-criteria — one package on iOS, primary
  acceptance; §spec:ios-ping-behavior).
- The consumer shall not add a second package and shall not call any
  registration function to enable iOS (§req:consolidation-success-criteria;
  §spec:ios-auto-wiring).
- The public Dart API — the `Ping` factory and the
  `PingData` / `PingResponse` / `PingSummary` / `PingError` shapes — shall be
  unchanged from the consolidation, save the removal of the iOS `register()`
  step and the `dart_ping_ios` import (§req:consolidation-constraints — public
  API unchanged; §spec:stats-event-model owns the 10.0.0 model surface).

**Why one package now, when it was two before:** the packages were separate
only because Flutter platform channels require the Flutter plugin machinery,
which a pure-Dart package cannot host. With native code now bundleable from a
pure-Dart package via a build hook (§spec:ios-code-asset-build-hook), that
constraint is gone, and the platform split no longer reflects a real domain
boundary — iOS is just another platform branch of one package
(§req:consolidation-problem-statement). The original #28 request was narrower
("rename `dart_ping_ios` to `dart_ping_flutter`"); folding iOS into the
pure-Dart `dart_ping` answers the same underlying need — fewer packages,
platform dispatch handled inside the package — without introducing a
Flutter-only umbrella package that would still fail the pure-Dart gate
(§spec:pure-dart-preserved).

**This is the headline slice;** the sections below are the mechanism it
requires: the code-asset build hook, the FFI binding, the preserved pure-Dart
gate, the auto-wiring, the background-isolate fix, and the retirement of
`dart_ping_ios`.

## iOS native engine ships as a build-hook code asset §spec:ios-code-asset-build-hook
*Status: not started*

`dart_ping` carries the native iOS ICMP engine and compiles it into a
**code asset** (a native dynamic library, linked at app-build time and reached
over `dart:ffi`) from a build hook (`hook/build.dart`). The hook produces the
native asset **only when the build target's operating system is iOS**; for
every other target — pure-Dart desktop, server, Android, and the analyzer /
`dart pub get` path — it produces no code asset and invokes no native
toolchain.

- When the build target is iOS, the build hook shall compile the in-repo
  native engine and emit one code asset that the Dart side opens over
  `dart:ffi` (§req:consolidation-constraints — FFI, not platform channels;
  §spec:ios-ffi-binding).
- When the build target is not iOS, the hook shall emit no code asset and
  shall compile no native source, so non-iOS builds incur no Swift/native
  compilation, no download, and ship no iOS code
  (§req:consolidation-success-criteria — non-iOS consumers pay nothing;
  §req:consolidation-priorities — nice-to-have; §spec:pure-dart-preserved).
- The native build shall be driven by the consuming toolchain — `flutter`
  for a Flutter iOS app, `dart` for a pure-Dart build — with no requirement
  that `dart_ping` be a Flutter plugin (§req:consolidation-constraints — single
  published package).

**Why a build-hook code asset rather than a Flutter plugin:** this is the
mechanism that lets one pure-Dart package own native iOS code. A Flutter plugin
forces a `flutter` SDK dependency and a `plugin: platforms:` block, which would
break the pure-Dart gate (§spec:pure-dart-preserved). The code-asset hook is a
pure-Dart facility (its `hooks` / `code_assets` dependencies are pure Dart), so
`dart_ping` keeps `flutter` out of its dependency graph entirely while still
shipping native iOS code. At iOS app-build time the Flutter/Xcode toolchain
compiles the asset and packages, embeds, and code-signs it as a framework — the
integration the federated plugin used to provide (§spec:spm-distribution),
now handled by the code-asset pipeline instead.

**The make-or-break risk (carried from §req:consolidation-open-decisions — iOS
code-asset feasibility):** that the native engine can be compiled and bundled
as an iOS code asset and linked into an app build — covering iOS
cross-compilation (SDK sysroot, architectures, minimum-version), framework
generation, and code signing — entirely outside the Flutter plugin machinery.
A complicating fact drives the language decision below: the first-party
code-asset toolchain compiles **C / C++ / Objective-C** (via `clang`), not
Swift. Two ways to honor the "reuse the existing Swift engine" constraint
(§req:consolidation-constraints):

- **Primary — retain Swift behind a C ABI.** Keep `PingEngine` / `ICMPPacket`
  (§spec:swift-icmp-engine) and expose a flat C entry surface from a thin
  `@_cdecl` Swift shim, compiled in the hook by invoking `swiftc` against the
  iOS SDK. Preserves the audited engine; cost is that the hook hand-rolls the
  iOS cross-compile because there is no first-party Swift code-asset helper.
- **Fallback — port the engine to Objective-C / C.** If `swiftc`-in-hook for
  an iOS code asset proves unworkable, re-port the small ICMP engine to
  Objective-C, which the first-party `clang`-based builder compiles directly.
  Still one package; cost is re-porting audited Swift.

If **neither** can satisfy the pure-Dart gate (§spec:pure-dart-preserved), the
last-resort fallback is the requirement's own: **do not consolidate** — keep
the two packages as they are today (§req:consolidation-priorities — the gate
overrides consolidation). The order is deliberate: a language re-port is a
smaller retreat than abandoning consolidation, so it is tried first.

**Why hand-write the C-ABI shim rather than generate Swift bindings:** the
compile step (Layer A — cross-compile Swift to an iOS code asset) and the
binding step (Layer B — how Dart calls the native symbols) are separate
problems, and only Layer B has a codegen alternative. There is no first-party
`native_toolchain_swift`, so *something* must hand-invoke `swiftc`/`xcrun` in
the hook regardless — the binding generators do not remove that step. For
Layer B, `dart-lang/native`'s `swift2objc` / `swiftgen` (+ `ffigen`) can
generate Dart bindings from `@objc`-annotated Swift via generated Objective-C
headers, replacing the hand-written `@_cdecl` shim. This is **considered and
not adopted** for this package: the native surface is three entry points
(`start` / `stop` / one event callback), so generated bindings save little; the
generators are experimental and would add the `objective_c` runtime bridge on
the exact async-callback path that must stay valid from a background thread
(§spec:ios-background-isolate); and a flat C function pointer driven by
`dart:ffi` `NativeCallable.listen` is the cleanest carrier for that callback.
The generator route would win only if the native API surface were large or
needed to expose rich Swift types a flat-C shim cannot carry comfortably —
neither holds here. So Layer A is hand-rolled `swiftc` (no alternative), and
Layer B is a hand-written `@_cdecl` flat-C shim (chosen over swift2objc for this
small surface).

**Tradeoff:** `dart_ping` gains a build hook and a native source tree, raising
its build complexity and its SDK floor (§spec:pure-dart-preserved owns the
floor). This is accepted as the price of one package; the hook's target-gated
short-circuit keeps the cost off every non-iOS consumer.

## Pure-Dart consumers need no Flutter SDK §spec:pure-dart-preserved
*Status: not started*

`dart_ping` remains a pure-Dart package. A CLI, server, or backend project adds
it with `dart pub add dart_ping` and pings on Linux / Windows / macOS desktop
**with no Flutter SDK installed and no Swift/iOS toolchain ever invoked**. This
is the non-negotiable gate: it overrides every other goal in package
consolidation.

- `dart pub add dart_ping` shall resolve and `dart run` / `dart test` shall
  work with no Flutter SDK present; `dart_ping`'s dependency graph shall
  contain no `flutter` SDK dependency (§req:consolidation-constraints —
  pure-Dart non-negotiable; §req:consolidation-success-criteria — pure-Dart
  unchanged, primary acceptance).
- On a non-iOS build, no Swift or iOS toolchain shall be invoked and no native
  compilation shall occur (§req:consolidation-quality-attributes —
  compatibility; §spec:ios-code-asset-build-hook).
- A pure-Dart, non-iOS consumer shall resolve, build, and run exactly as it did
  before consolidation — the added iOS code costs it nothing observable
  (§req:consolidation-success-criteria — non-iOS consumers pay nothing).

**Why this is a gate and not a goal:** the whole reason the packages were never
merged was that folding Flutter-plugin code into `dart_ping` would force a
Flutter SDK on pure-Dart consumers. Consolidation is only worth doing if that
promise survives. If `/roadmap` or implementation finds the gate cannot hold,
the correct outcome is to abandon consolidation, not to compromise the gate
(§req:consolidation-priorities). The code-asset approach is chosen precisely
because it keeps `flutter` out of the dependency graph
(§spec:ios-code-asset-build-hook).

**Tooling floor:** preserving the gate this way requires Dart 3.10 /
Flutter 3.38 or later, where build hooks and code assets are stable. Raising
`dart_ping`'s minimum SDK to that floor is accepted
(§req:consolidation-quality-attributes — tooling floor;
§req:consolidation-constraints — raised SDK floor). The current floor (≥3.8.0,
§spec:sdk-floor) rises to ≥3.10 as part of 10.0.0.

## iOS talks to the engine over `dart:ffi` §spec:ios-ffi-binding
*Status: not started*

On iOS the Dart layer drives the native engine over `dart:ffi`, not over a
`MethodChannel` / `EventChannel`. Starting a run is a foreign-function call;
per-probe events stream back through a native callback; stopping is a foreign
call. The observable `stream` contract is unchanged — the same sealed
`PingEvent`s in the same order, terminated by the same `PingSummary`
(§spec:ios-ping-behavior, §spec:stats-event-model).

- Listening to an iOS `Ping`'s `stream` shall start a native run; each Echo
  Reply, probe error, and the terminal summary shall arrive as the same
  `PingResponse` / `PingError` / `PingSummary` events produced today over the
  channel (§spec:ios-ping-behavior, §spec:ios-error-parity, §spec:ios-ttl).
- Per-probe events shall reach Dart through a native-to-Dart callback that can
  be invoked from the engine's background thread and delivered to the owning
  isolate's event loop, so events are not marshalled through the Flutter binary
  messenger (§req:consolidation-quality-attributes — concurrency;
  §spec:ios-background-isolate).
- Each `Ping` instance shall own its own native run handle and its own
  callback, so concurrently running instances do not share native state and
  need no id-based demultiplexing of a shared event stream
  (§spec:concurrent-isolation).
- Round-trip times shall preserve microsecond resolution across the FFI seam,
  matching the precision guarantee the channel payload provides today
  (§spec:stats-precision, §spec:stats-ios).
- iOS round-trip statistics shall continue to be computed by the shared core
  accumulator from per-probe times, identical to the other platforms by
  construction (§spec:stats-cross-platform, §spec:stats-ios) — the seam change
  does not move the statistics computation.

**Why FFI replaces channels:** platform channels are the single cause of both
issues package consolidation resolves — they require the Flutter plugin that
blocks #28, and
they route through the root-isolate binary messenger that breaks #48. FFI
removes both at once: it needs no plugin (enabling §spec:single-package-ios)
and no binary messenger (enabling §spec:ios-background-isolate). The
maintainer's own diagnosis on #48 — "use `dart:ffi` instead of platform
channels" — is the mechanism adopted here.

**Why per-instance handles rather than the shared broadcast stream:** the
channel design multiplexed all runs onto one `EventChannel` broadcast stream
and demultiplexed by a generated run `id` (§spec:concurrent-isolation). FFI
removes the reason for sharing — each instance can hold its own native handle
and callback — so the id-demux machinery is dropped. The
deferred decision on the exact FFI callback shape
(native threads, the native-callable callback, ports) is settled here in favor
of a per-instance asynchronous native callback that is valid from any isolate
(§req:consolidation-open-decisions — FFI threading / isolate model).

**Tradeoff:** the engine's results must cross an FFI ABI (flat C types, manual
memory ownership for host strings and the per-event payload) rather than the
channel's automatic codec. Accepted: the ABI surface is small (start / stop /
one event callback) and is the prerequisite for both fixes.

## iOS ping works from any isolate §spec:ios-background-isolate
*Status: not started*

Running an iOS ping from a **secondary (background) isolate** produces
per-probe responses and a terminal summary without throwing. The
`BackgroundIsolateBinaryMessenger ... is invalid` /
"Background isolates do not support setMessageHandler()" failure no longer
occurs, because the iOS path no longer touches the Flutter binary messenger
(§spec:ios-ffi-binding).

- When a `Ping` is constructed and its `stream` listened to from a non-root
  isolate on iOS, the run shall produce responses and a summary without
  throwing a background-isolate messenger error
  (§req:consolidation-success-criteria — background isolates work, closes #48).
- iOS ping shall be usable from any isolate, matching how ping already works in
  isolates on the subprocess platforms (§req:consolidation-user-stories — ping
  off the main thread; §req:consolidation-quality-attributes — concurrency).

**Why this is asserted explicitly rather than left implicit:** the
background-isolate fix is a *consequence* of choosing FFI, not a separate
feature — but stating it as its own observable outcome guards against an FFI
design that quietly reintroduces a root-isolate dependency (for example, a
callback that must be registered on the root isolate). The criterion exists so
that regression is caught (§req:consolidation-open-decisions — FFI threading /
isolate model). It is verified on a real iOS target as part of the manual
acceptance path, since live ICMP and an iOS runtime are not reproducible in CI
(§spec:ci, §spec:ios-tests).

## iOS auto-wires; no `register()` §spec:ios-auto-wiring
*Status: not started*

iOS support activates with no consumer-written wiring. The `Ping` factory's
`'ios'` branch constructs the FFI-backed iOS implementation directly, the same
way the other branches construct their platform `Ping`s
(§spec:public-api-stability). The `Ping.iosFactory` registration hook and
`DartPingIOS.register()` are gone.

- A consumer shall obtain a working iOS `Ping` from `Ping(host, ...)` with no
  prior registration call and no conditional import
  (§req:consolidation-success-criteria — no manual platform wiring;
  §req:consolidation-user-stories — add one package, iOS just works).
- The `Ping` factory shall dispatch to the iOS implementation internally on
  `Platform.operatingSystem == 'ios'`, with no `iosFactory` indirection
  (§req:consolidation-constraints — public API unchanged except the removed
  `register()`).

**Why the indirection can be removed now:** `Ping.iosFactory` existed only so
the pure-Dart `dart_ping` could call into iOS code that lived in a *separate*
package without depending on it — a late-bound seam across the package
boundary. With iOS in the same package, the factory references the
implementation directly and the seam is unnecessary. FFI is part of the core
SDK and available on every platform, so referencing the iOS implementation from
shared Dart code does not pull native symbols into non-iOS builds — the native
library is only *opened* on the iOS branch, which only runs on iOS
(§spec:pure-dart-preserved). Removing `register()` is the one intentional
break to the §spec:public-api-stability contract this area makes, beyond the
10.0.0 model redesign (§spec:stats-event-model); it is called out in migration
(§spec:dart-ping-ios-retired).

## `dart_ping_ios` is retired §spec:dart-ping-ios-retired
*Status: not started*

`dart_ping_ios` is discontinued. iOS support is no longer obtained from a
second package, and no new functional release of `dart_ping_ios` is required to
get it. The package is marked discontinued on pub.dev rather than kept as a
forwarding shim.

- Getting iOS support shall require no `dart_ping_ios` dependency; depending on
  `dart_ping` alone shall be sufficient (§req:consolidation-constraints —
  single published package; §spec:single-package-ios).
- Migration for an existing `dart_ping_ios` consumer shall be: remove the
  `dart_ping_ios` dependency, delete the `DartPingIOS.register()` call, and
  raise the SDK floor to the consolidation baseline (§spec:pure-dart-preserved);
  no other source change is required, because the public `Ping` API and the
  event model are otherwise unchanged (§req:consolidation-user-stories —
  migration notes; §req:consolidation-open-decisions — migration surface).
- The bundled example shall import only `dart_ping` and call no `register()`
  (§req:consolidation-priorities — high; updated example).

**Why retire outright rather than keep a thin wrapper:** a forwarding
`dart_ping_ios` that re-exported the consolidated iOS path would preserve a
second published artifact, version-alignment burden, and the `register()` call
— the exact costs consolidation exists to remove
(§req:consolidation-problem-statement). A clean discontinuation with documented
migration is a one-time,
well-bounded edit for consumers and leaves one package to maintain. The prior
`dart_ping_ios` releases remain available for consumers who cannot adopt the
raised SDK floor; they continue to work over the channel implementation
(§spec:spm-distribution) but receive no further iOS development.

**Why no separate later major:** consolidation folds into the unreleased
`dart_ping` 10.0.0 train (§req:consolidation-constraints — folds into 10.0.0)
rather than waiting for a future major, because 10.0.0 is already a breaking
release (§spec:stats-event-model) and `register()`-removal and the SDK-floor
raise are breaking changes best shipped once, together.
