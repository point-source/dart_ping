# Specification

This document covers five areas, matching REQUIREMENTS.md:

1. **iOS SPM migration (#73)** — `§spec:swift-icmp-engine` …
   `§spec:ios-tests` below (implemented).
2. **Maintenance & modernization refresh** — the `§spec:dependency-currency`
   … `§spec:code-audit` sections (complete).
3. **`base_ping` stream lifecycle robustness (#76)** —
   `§spec:stream-lifecycle-robustness` (implemented). A focused
   follow-up to two hang paths deferred from `§spec:code-audit`.
4. **Continuous integration & coverage expansion (#74, #77)** — the
   `§spec:ci` … `§spec:coverage-expansion` sections (implemented). This is
   new work *beyond* the refresh's "fill gaps only" scope, which had
   deliberately excluded CI (§spec:test-coverage).
5. **Interface selection (#72)** — `§spec:interface-selection` …
   `§spec:interface-listing` at the very end (not started). An optional way
   to pin pings to a chosen network interface or source address on the
   subprocess platforms, with a helper to enumerate the host's interfaces.
   Additive on top of the existing `Ping` API.

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
