# Specification

This document covers three areas, matching REQUIREMENTS.md:

1. **iOS SPM migration (#73)** — `§spec:swift-icmp-engine` …
   `§spec:ios-tests` below (implemented).
2. **Maintenance & modernization refresh** — the `§spec:dependency-currency`
   … `§spec:code-audit` sections (complete).
3. **`base_ping` stream lifecycle robustness (#76)** —
   `§spec:stream-lifecycle-robustness` at the end (not started). A focused
   follow-up to two hang paths deferred from `§spec:code-audit`.

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
  infrastructure (§req:refresh-constraints).

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
