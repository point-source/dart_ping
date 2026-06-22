# Requirements

This document tracks the following areas of work:

- **iOS SPM migration (#73)** — *shipped in `dart_ping_ios` 5.0.0.*
  Replace the `flutter_icmp_ping` dependency with a native Swift ICMP
  engine and ship under Swift Package Manager. Captured in the
  `§req:problem-statement` … `§req:priorities` sections below.
- **Maintenance & modernization refresh** — a cross-package pass to bring
  dependencies, SDK constraints, documentation, and test coverage current,
  and to surface bugs / security flaws / improvements across the Dart and
  native Swift code. Captured in the `§req:refresh-*` sections.
- **`base_ping` stream lifecycle robustness (#76)** — fix two edge paths
  in the core `dart_ping` stream where a consumer can hang forever
  instead of seeing an error: an unmapped non-zero exit code, and a
  failed process launch (e.g. a missing `ping` binary). Surfaced by the
  Dart code audit (`§spec:code-audit`). Captured in the
  `§req:robustness-*` sections.
- **IPv6 / address-family error clarity (#69)** — on IPv6-enabled
  networks (notably mobile data), pinging an IP can fail with a
  misleading "Unknown Host" error when the `ipv6` flag and the target's
  address family disagree, or when the network/adapter cannot route the
  selected family. Treat `ipv6` as an exclusive address-family selector,
  validate obvious literal mismatches up front, and surface honest,
  consistent errors instead of mislabeling them. Captured in the
  `§req:ipfamily-*` sections at the end.
- **Interface selection (#72)** — let a developer choose which network
  interface (by interface name or by local source address) pings
  originate from, on the desktop platforms (Linux/Android, macOS,
  Windows), with a nice-to-have helper to enumerate the available
  interfaces. Captured in the `§req:interface-*` sections at the end.
- **Concurrent-ping isolation (#70)** — a reported defect where two or
  more `Ping` instances run at the same time report the same round-trip
  results instead of each host's own, first seen on Android. Fix so that
  concurrent `Ping` instances are fully independent. Captured in the
  `§req:concurrent-*` sections at the end.
- **Summary statistics (#63)** — surface the richer round-trip
  statistics the native `ping` already prints (min / avg / max / stddev),
  plus a mean-consecutive-delta jitter figure and packet-loss %, both in
  the run summary and as live running stats during a run, with full
  cross-platform parity including iOS. Delivered via a from-scratch
  redesign of the stream's event/data classes (a sealed event union plus a
  reusable round-trip-stats value object), folded into the
  already-unreleased breaking `dart_ping` 10.0.0 / `dart_ping_ios` 6.0.0
  majors. Captured in the `§req:stats-*` sections at the end.
- **NAT64 / IPv6-only IP-literal reachability (#52)** — on iOS over
  cellular (mobile data), pinging a bare IPv4 literal fails outright,
  while a hostname works and the same literal works over Wi-Fi, because
  the carrier runs an IPv6-only (NAT64/DNS64) network that synthesizes a
  routable address for hostnames but not for raw IP literals. Make the
  literal ping actually succeed via the platform's NAT64 address
  synthesis (as Apple's own guidance and third-party ping apps do),
  behind an explicit option that is enabled by default — extending the
  #69 scope boundary, which made the error honest but declined to make
  the ping work. Captured in the `§req:nat64-*` sections at the end.
- **Windows interface-listing round-trip contract (#85)** — the
  interface-selection helper (#72) promised a listed interface could be
  "passed back into a `Ping`," and a test read that as *every interface
  name* round-tripping on *every* platform. That is false on Windows by
  the package's own design: Windows `ping` binds only by source address
  and a bare interface name is rejected. Once CI ran the core suite on a
  real Windows host, the contradiction turned the Windows check red. Make
  the round-trip contract honest per platform — the source **address**
  round-trips everywhere, the **name** only where the OS binds by name —
  without changing any platform's runtime behavior. Captured in the
  `§req:windows-roundtrip-*` sections at the end.
- **CI on PRs to `develop`** — the repository follows a gitflow model
  where feature branches merge into a `develop` integration branch, which
  periodically merges to `main` for release. The existing CI
  (`§spec:ci`) gates only PRs to `main`, so a feature branch merges into
  `develop` with no checks and breakage accumulates there unseen until the
  `develop`→`main` release PR runs CI — late, batched, and hard to
  attribute. Extend CI so the same gate runs on PRs targeting `develop`,
  and protect `develop` like `main`. Captured in the `§req:ci-develop-*`
  sections at the end.
- **Package consolidation — one `dart_ping` with FFI-backed iOS (#28, #48)** —
  fold `dart_ping_ios` into a single pure-Dart `dart_ping` that carries the
  native iOS engine as a build-hook code asset and drives it over `dart:ffi`,
  retiring the second package and the `register()` step (#28) and fixing iOS
  ping inside background isolates (#48), without losing pure-Dart support on
  hosts with no Flutter SDK. Folds into the unreleased `dart_ping` 10.0.0
  train. Captured in the `§req:consolidation-*` sections at the end.
- **macOS all-timeout summary (#92)** — on macOS, a run where every probe
  times out but the first hop returns TTL-exceeded ICMP errors makes the
  native `ping` exit with code `2`, which `PingMac` leaves unmapped, so
  the consumer gets a thrown exception instead of the 100%-loss summary
  already built. Map exit `2` to the same `noReply` outcome as exit `1`
  (pure silence) so an all-timeout run deterministically yields a summary.
  Refines `§req:robustness-*` without weakening its unmapped-exit
  guarantee. Captured in the `§req:mac-all-timeout-*` sections at the end.

---

## Problem statement §req:problem-statement

The target users are Flutter app developers who use `dart_ping` for
network ping on iOS and who have enabled (or want to enable) Flutter's
Swift Package Manager (SPM) build mode.

These developers cannot consume `dart_ping_ios` under SPM. The iOS
support package carries no native iOS code of its own — it is a thin
Dart wrapper that delegates to the third-party `flutter_icmp_ping`
plugin, which ships only a CocoaPods podspec. On an SPM-only project
there is no path to add iOS ping support, and the maintainer cannot fix
it directly because the native code lives in a dependency they do not
control.

Current solutions fall short because Flutter is moving toward SPM as the
default iOS/macOS build system and CocoaPods is on a deprecation path.
New Flutter projects increasingly default to SPM, so a growing share of
users find `dart_ping`'s iOS story broken. The problem is therefore
growing rather than static: it gets worse as Flutter's SPM adoption
rises.

Separately, the existing iOS path has drifted from the other platforms.
The `ttl` parameter is ignored, TTL-exceeded errors (recently fixed on
Android in #49) never surface on iOS, several error types are unmapped,
and the iOS summary omits the per-run error list. So iOS already behaves
differently from Android/Linux/macOS/Windows even before SPM enters the
picture.

Direction agreed with the maintainer (recorded here as the framing for
everything downstream): replace the `flutter_icmp_ping` dependency with a
native Swift ICMP implementation owned by this repository, shipped as a
true federated plugin with SPM support. This both unblocks SPM and gives
the maintainer control to close the parity gaps.

## Success criteria §req:success-criteria

- A Flutter app with SPM enabled and **no CocoaPods/Podfile present** can
  add `dart_ping_ios` and run network pings on iOS, producing correct
  per-probe responses and a run summary. *(must-have)*
- The example app runs on an iOS simulator or device with SPM enabled,
  no `Podfile`, and ping works end-to-end. *(primary acceptance test)*
- The new iOS implementation has **no dependency on `flutter_icmp_ping`**
  or any other CocoaPods-only package; the native ping logic lives in
  this repository as Swift.
- iOS reaches behavioral parity with the other platforms:
  - honors the `ttl` parameter (limits the number of network hops);
  - emits `timeToLiveExceeded` events when a hop limit is exceeded;
  - surfaces the full error set the other platforms report
    (`timeToLiveExceeded`, `requestTimedOut`, `unknownHost`, `noReply`,
    `unknown`);
  - includes the per-run error list in the summary.
- App developers do not have to add special entitlements or take extra
  App Store review steps to use it. *(soft — to confirm during `/plan`)*
- Automated tests cover the iOS ping behavior where feasible.
- Existing CocoaPods-based consumers are unaffected: the prior
  `dart_ping_ios` release remains usable for projects that have not
  migrated to SPM.

## User stories §req:user-stories

- As a Flutter developer building an iOS app with SPM enabled, I want to
  add `dart_ping_ios` and ping a host so that I get round-trip responses
  and a summary **without installing CocoaPods**.
- As a developer pinging from iOS, I want to set a TTL and receive a
  "time-to-live exceeded" event so that I can build traceroute-style
  diagnostics, the same way I can on Android, Linux, macOS, and Windows.
- As a cross-platform developer, I want iOS errors (timeout, unknown
  host, no reply, TTL exceeded, unknown) and the summary's error list to
  match the other platforms so that my shared code handles failures
  identically everywhere.
- As an existing user who has not migrated to SPM, I want my current
  CocoaPods-based setup to keep working on the previous version so that
  the migration happens on my schedule, not as a forced break.
- As the package maintainer, I want the iOS native code to live in this
  repository so that I can fix bugs and add features without waiting on
  an upstream third-party package.

## Quality attributes §req:quality-attributes

- **Compatibility:** works under Flutter's Swift Package Manager build
  mode. CocoaPods support is dropped in the new version (SPM-only). iOS
  only — macOS continues to be served natively by the core `dart_ping`.
  The minimum supported iOS version is not yet decided and will be set in
  `/plan`.
- **Parity / reliability:** observable behavior — responses, summary,
  errors, and accepted parameters — matches the other platforms.
- **Security / permissions:** should not require special entitlements or
  unusual App Store review steps from the consuming app. *(to confirm in
  `/plan`)*
- **Testability:** behavior is verifiable via the example app on iOS and,
  where feasible, via automated tests.
- **Accuracy:** round-trip timing is comparable to the previous
  `flutter_icmp_ping`-based implementation.

## Constraints §req:constraints

- Native iOS ping is implemented in **Swift**, owned in this repository,
  replacing the `flutter_icmp_ping` dependency.
- Distribution is **SPM-only** for the new version; no podspec ships with
  it. Existing CocoaPods consumers remain on the prior `dart_ping_ios`
  release.
- The public Dart API — the `Ping` interface and the
  `PingData` / `PingResponse` / `PingSummary` / `PingError` shapes — is
  unchanged, so existing app code keeps working without edits.
- This is a breaking change and ships as a **new major version** of
  `dart_ping_ios`.
- Scope is **iOS only**.

## Priorities §req:priorities

- **Must-have (non-negotiable):** SPM works at all. An SPM-enabled app
  can use `dart_ping_ios` on iOS with no CocoaPods, backed by a native
  Swift implementation and with no `flutter_icmp_ping` dependency. This is
  the minimum bar for shipping.
- **High priority (strong follow-on, same effort):** iOS feature parity —
  honor `ttl`, emit `timeToLiveExceeded`, cover the full error set, and
  include errors in the summary. Worth doing now that the maintainer owns
  the native code, but secondary to "SPM works at all."
- **Nice-to-have:** automated iOS tests; a documented minimum iOS version
  and entitlement guidance for app developers.

---

# Maintenance & modernization refresh

A periodic health pass over both packages — `dart_ping` (core) and
`dart_ping_ios` (the native Swift / SPM iOS plugin). Not tied to a single
GitHub issue; the driver is accumulated drift, not a new feature.

## Refresh — problem statement §req:refresh-problem-statement

The target users are existing consumers of `dart_ping` / `dart_ping_ios`
and the package maintainer. Both packages have drifted from current Dart /
Flutter tooling:

- **Dependencies are behind.** Direct dev-dependencies in particular are
  stale — `lints` is pinned at `^2.0.0` while `6.x` is resolvable,
  `flutter_lints` at `^2.0.1` vs `6.0.0`, and `test` is locked well below
  its resolvable `1.31`. `js` (transitive) is discontinued. Consumers
  resolving fresh see old, sometimes superseded, packages.
- **The SDK floor is conservative.** Both packages allow `sdk: ">=3.0.0"`,
  which blocks adoption of newer lint rules and language conveniences that
  the current toolchain (Dart 3.12 / Flutter 3.44) offers.
- **Docs have drifted.** The root `README` predates the native-Swift iOS
  rewrite (5.0.0); package READMEs, CHANGELOGs, and dartdoc may not reflect
  current platform support, the SPM-only iOS story, or recently fixed
  behavior.
- **Test coverage is uneven.** `dart_ping` has known *failing* tests
  (the macOS and Windows "TTL Exceeded" parse cases crash because the
  regex lacks a `seq` capture group), and several behaviors — parser error
  paths, the iOS event mapper, stream lifecycle — are thinly covered.
- **Config has gone stale.** Both `analysis_options.yaml` files still
  configure `dart_code_metrics`, which is no longer part of the lints
  toolchain and is effectively dead config.
- **The native Swift code has never had a focused audit.** The iOS ICMP
  engine (socket setup, ICMP packet construction/parsing, buffer bounds,
  error mapping) is new and owned in-repo but has not been reviewed for
  bugs or security flaws.

Left alone, this drift compounds: each release gets harder to cut,
consumers on current SDKs hit avoidable friction, and undiscovered defects
(especially in the new native code) ship unnoticed.

## Refresh — success criteria §req:refresh-success-criteria

Observable, verifiable outcomes:

- **Dependencies current.** `dart pub outdated` (and `flutter pub outdated`
  for the iOS package) shows every *direct* dependency at its latest
  resolvable version, including the `lints` 6 / `flutter_lints` 6 majors.
  `dart pub get` / `flutter pub get` resolve cleanly in both packages.
  *(must-have)*
- **Static analysis is clean.** `dart analyze` (core) and `flutter analyze`
  (iOS) report **zero** issues under the upgraded lint rule sets.
  *(must-have)*
- **SDK floor raised only as far as it pays for itself.** The `sdk`
  constraint is bumped to the lowest stable version that the upgraded
  tooling (lints 6, test 1.31) and any adopted language features actually
  require — and no further. The chosen floor and its justification are
  recorded in the CHANGELOG. *(must-have)*
- **All tests pass.** `dart test` passes fully in `dart_ping` and
  `dart_ping_ios` with **no known-failing or skipped cases** — including
  the previously-crashing macOS/Windows "TTL Exceeded" parse tests.
  *(must-have)*
- **Coverage gaps filled.** Thinly covered behavior — parser error/edge
  paths, the iOS event mapper, and stream start/stop lifecycle — gains
  tests. (Goal is to close obvious gaps, not hit a numeric threshold, and
  no CI is introduced in this pass.)
- **Docs accurate.** The root `README`, both package `README`s,
  `CHANGELOG`s, and public dartdoc reflect current reality: supported
  platforms, the SPM-only native-Swift iOS implementation (5.0.0), the
  current SDK floor, and recently fixed behavior. A new reader can install
  and use each package from the docs without hitting a stale instruction.
- **Audit findings surfaced.** A review of the Dart code (both packages)
  **and** the native Swift ICMP engine produces an enumerated list of
  bugs, security flaws, and improvement opportunities, each triaged
  (fix-now / defer / won't-fix). Security-relevant Swift findings — socket
  configuration, ICMP packet parsing, buffer bounds, untrusted-input
  handling — are explicitly assessed.

## Refresh — user stories §req:refresh-user-stories

- As a consumer on a current Dart/Flutter SDK, I want `pub get` to resolve
  up-to-date dependencies and `analyze` to pass, so that adding these
  packages doesn't drag stale or discontinued transitive deps into my app.
- As a maintainer cutting the next release, I want a green `dart test` with
  no known-failing cases, so that I can release with confidence instead of
  mentally excusing "expected" failures.
- As a developer reading the docs, I want the README and CHANGELOG to
  describe the *current* iOS implementation (native Swift, SPM-only) and
  supported platforms, so that I don't follow instructions for a version
  that no longer exists.
- As a security-conscious adopter, I want the native iOS ICMP code to have
  been reviewed for socket and packet-parsing flaws, so that I can trust it
  with untrusted network input.
- As the maintainer, I want a triaged list of bugs and improvements across
  both packages, so that I can decide what to fix now versus track for
  later instead of rediscovering issues ad hoc.

## Refresh — quality attributes §req:refresh-quality-attributes

- **Compatibility:** do not raise the SDK floor beyond what delivers a
  concrete benefit; preserve the widest consumer compatibility consistent
  with the upgraded tooling. The public Dart API stays unchanged unless a
  change is independently justified.
- **Maintainability:** the codebase is lint-clean under current rules, and
  analysis config carries no dead settings (e.g. the unmaintained
  `dart_code_metrics` block is removed or replaced with a maintained
  equivalent).
- **Security:** the native Swift ICMP engine is reviewed for unsafe socket
  use, out-of-bounds packet reads, and mishandling of untrusted inbound
  data.
- **Testability:** behavior changes and bug fixes in this pass land with
  tests; no test is left in a known-failing state.
- **Documentation quality:** docs are accurate and self-consistent across
  the root and both packages.

## Refresh — constraints §req:refresh-constraints

- Dependencies move to the **latest resolvable major** versions; if a major
  bump forces code changes (e.g. new lint rules), those changes are in
  scope.
- **Breaking changes are acceptable only when justified.** Raising the SDK
  floor or a dep major may force a new package major — that is fine when it
  buys a concrete benefit, but no break is introduced that "doesn't buy us
  anything."
- The SDK floor is set to the **lowest** stable version that the adopted
  tooling/features require — no speculative bump to match the installed
  toolchain.
- **No new CI/coverage-threshold infrastructure** is added in this pass;
  the testing goal is to fill gaps and fix known failures.
- The audit covers **both** the Dart code and the native Swift/iOS code.

## Refresh — priorities §req:refresh-priorities

- **Must-have:** dependencies current at latest resolvable majors;
  `analyze` clean; full `dart test` green with no known-failing cases; SDK
  floor bumped only as far as justified and documented; docs accurate to
  the shipped reality.
- **High priority:** an enumerated, triaged audit of bugs / security flaws
  / improvements across Dart and native Swift, with security-relevant Swift
  findings explicitly assessed; fixes applied for findings that are cheap
  and clearly correct.
- **Nice-to-have:** deeper test coverage beyond the obvious gaps; replacing
  the stale `dart_code_metrics` config with a maintained metrics/lint
  alternative.

---

# base_ping stream lifecycle robustness (#76)

Two related medium-severity robustness defects in the core `dart_ping`
ping stream, deferred from the maintenance audit (`§spec:code-audit`)
because they were not cheap-and-clearly-correct enough to fix inline.
Both only trigger on edge paths; normal runs are unaffected.

## Robustness — problem statement §req:robustness-problem-statement

The target users are developers consuming `dart_ping`'s `Ping` stream —
typically with `await for`, `.drain()`, `.last`, or by awaiting `stop()`.
They expect the stream to always finish: either delivering responses and
a summary, or surfacing an error they can catch.

On two edge paths the stream instead **hangs forever** — it never emits
the failure and never closes, so the consumer's `await` blocks
indefinitely:

- **Unmapped non-zero exit code.** When the `ping` process exits with a
  non-zero code that the platform does not recognize as a known error,
  the cleanup logic throws from inside the subscription's `onDone`
  callback. Because that callback's future is not awaited, the exception
  is swallowed and — critically — the stream controller is never closed.
  The consumer hangs on an exotic exit code.
- **Process-launch failure.** When the `ping` binary cannot be started
  (e.g. it is not installed), the failure escapes during stream start-up
  before the subscription is wired up. The intended "Could not find ping
  binary…" error never reaches the consumer, nothing is emitted, and the
  stream never closes — so the consumer hangs instead of seeing the
  error.

Current behavior fails these users because a hang is the worst possible
outcome: there is no error to catch, no completion to await, and no
timeout — the calling code simply stalls. These paths are rare (unusual
exit codes, a missing binary), but when they happen they are silent and
unrecoverable from the consumer's side.

A third, lower-severity observation is folded in: the stream merges the
process's stderr and stdout *before* splitting into lines, which could in
theory interleave and corrupt a diagnostic line. In practice `ping` is
line-buffered on a single stream, so this has not been observed — but it
is in scope to harden against.

## Robustness — success criteria §req:robustness-success-criteria

Observable, end-to-end outcomes a tester can demonstrate against the
`Ping` stream:

- **Missing-binary launch failure surfaces an error, then closes.** With
  no usable `ping` binary on the system, a consumer listening to the
  stream receives an error event whose message indicates the ping binary
  could not be found, and the stream then closes — within bounded time,
  with no hang. *(must-have)*
- **Any other launch failure surfaces an error, then closes.** If the
  process fails to start for any other reason, the consumer receives an
  error event and the stream closes rather than hanging. *(must-have)*
- **Unmapped non-zero exit surfaces an error, then closes.** When the
  ping process exits with a non-zero code the platform does not map to a
  known `PingError`, the consumer receives an error event and the stream
  closes — instead of the stream staying open forever. *(must-have)*
- **The stream always terminates.** On every path — normal completion,
  a mapped error exit, an unmapped exit, a launch failure, and
  cancel/`stop()` — the stream closes exactly once, so a consumer
  awaiting completion always returns and never deadlocks. *(must-have)*
- **Normal runs are unchanged.** For a successful run (zero exit) or a
  recognized error exit, the consumer still receives the same per-probe
  responses, the run summary, and the per-run error list as before, and
  the stream closes as before. *(must-have — regression guard)*
- **Diagnostic lines arrive intact.** Each response/error line the
  consumer expects is delivered whole; lines are not corrupted, split,
  or dropped as a result of stderr and stdout being combined before
  line-splitting. *(high)*
- **The edge paths are covered by automated tests.** Missing-binary
  launch failure, unmapped non-zero exit, and unchanged normal
  completion each have a test that fails if the stream hangs or
  swallows the error. *(high — aligns with `§req:refresh-success-criteria`
  stream-lifecycle coverage)*

## Robustness — user stories §req:robustness-user-stories

- As a developer pinging a host, when the `ping` binary is missing I want
  to receive a clear error I can catch so that my `await for` loop fails
  fast instead of hanging forever.
- As a developer, when `ping` exits with an unusual code my platform
  does not recognize, I want the stream to surface an error and close so
  that I can handle the failure rather than stall.
- As a developer who awaits stream completion (`.drain()`, `.last`, or
  `stop()`), I want the stream to always close so that my code never
  deadlocks on an edge path.
- As an existing `dart_ping` user, I want normal ping runs to behave
  exactly as they do today so that this fix is invisible to working code.

## Robustness — quality attributes §req:robustness-quality-attributes

- **Reliability:** the stream terminates on every code path. No path
  leaves the controller open; failures are observable, not silent.
- **Compatibility:** the public API is unchanged — the `Ping` interface
  and the `PingData` / `PingResponse` / `PingSummary` / `PingError`
  shapes stay the same. Errors surface through the stream's existing
  error channel that consumers already handle; normal-run output is
  byte-for-byte equivalent.
- **Testability:** each edge path is exercised by an automated test that
  fails on a hang or a swallowed error, runnable under `dart test`
  without a live network.

## Robustness — constraints §req:robustness-constraints

- The fix is internal to the core `dart_ping` package
  (`lib/src/ping/base_ping.dart`); no change to the public API or to
  `dart_ping_ios`.
- This is a **non-breaking, patch-level** change to `dart_ping`.
- Scope is the three items above (two hang paths + stderr/stdout line
  integrity). Surfaced by, and traceable to, the audit
  (`§spec:code-audit`); related to the refresh's stream-lifecycle test
  goal in `§req:refresh-success-criteria`.

## Robustness — priorities §req:robustness-priorities

- **Must-have:** both hang paths fixed — a missing binary and an unmapped
  exit code each surface a catchable error and close the stream, with
  normal runs unchanged.
- **High priority:** automated tests covering the missing-binary,
  unmapped-exit, and normal-completion paths; harden stderr/stdout line
  integrity so diagnostic lines arrive intact.
- **Nice-to-have:** none beyond the above — this is a focused robustness
  fix.

---

# IPv6 / address-family error clarity (#69)

A correctness-of-errors fix in `dart_ping`'s address-family handling.
On IPv6-enabled networks — most visibly mobile data — pinging an IP can
fail with a misleading "Unknown Host" error even though nothing about a
name was being resolved. The driver is GitHub issue #69.

## IPv6 — problem statement §req:ipfamily-problem-statement

The target users are Flutter/Dart developers using `dart_ping` for ping
diagnostics, especially those whose apps run on mobile devices. Cellular
carriers increasingly provide IPv6-only connectivity (464XLAT / NAT64
with DNS64), so a growing share of app sessions run on networks where
IPv4 and IPv6 behave differently.

The reported problem (#69): on a mobile-data connection with IPv6 enabled
but the `ipv6` parameter left `false`, pinging a literal IP address fails
with an "Unknown Host" error, while pinging the same target by hostname
succeeds. "Unknown host" is a name-resolution failure — but a literal IP
needs no resolution, so the error is misleading and sends developers down
the wrong debugging path.

Underneath, native ping selects its address family **exclusively**: the
IPv4 tool refuses an IPv6 target and the IPv6 tool refuses an IPv4 target.
On macOS the IPv4 `ping` even reports a mismatched IPv6 literal verbatim
as "Unknown host"; on Linux the unified `ping` reports an address-family
error for the same mismatch. `dart_ping` runs `ping6` when `ipv6:true` and
`ping` otherwise, so its `ipv6` flag is already, in effect, an exclusive
family selector — but the library neither validates that the target's
family matches the flag nor normalizes the resulting failure. It passes
the mismatched target through (or forces a family during the iOS engine's
resolution) and then surfaces whatever generic error comes back — often
"unknown host" — masking the real cause: a wrong family, no route for the
selected family, or an adapter without that family enabled.

The "hostname works but the IP fails" signature is the tell. On an
IPv6-only mobile network, DNS64 hands back a synthesized IPv6 address for
a hostname, which the engine can route, while a bare IPv4 literal has no
such path — and the failure is then reported as an unrelated "unknown
host." Current behavior fails these users because the error names the
wrong problem: developers cannot distinguish "that host does not exist"
from "you asked for a family this network/flag can't serve."

The problem is **growing** (carriers keep moving to IPv6-only cores),
**intermittent** (only on certain networks), and therefore **expensive to
diagnose** — it is hard to reproduce on a developer's Wi-Fi and easy to
misattribute to the wrong layer.

## IPv6 — success criteria §req:ipfamily-success-criteria

Observable, verifiable outcomes:

- **The address family is selected explicitly and exclusively.** The
  caller chooses IPv4-only or IPv6-only through an explicit, unambiguous
  selection — not a boolean flag whose `false` value can be misread as
  "prefer IPv4 / dual-stack." Across all supported platforms the selected
  family is the *only* family attempted, matching the native
  `ping`/`ping6` (`-4`/`-6`) semantics the library already relies on. This
  is documented. *(must-have)*
- **Family mismatch on a literal fails fast, clearly, and
  consistently.** Pinging a literal IP whose family contradicts the
  selected family is rejected **in both directions** — IPv4 selected with
  an IPv6 literal *and* IPv6 selected with an IPv4 literal — with a single,
  consistent, catchable error (a thrown `ArgumentError` before the stream
  starts) that names the actual problem (an address-family mismatch),
  identical in shape across platforms. Never a misleading "Unknown Host",
  never a hang. *(must-have)*
- **"Unknown host" means what it says.** `unknownHost` / "Unknown Host"
  is emitted only for genuine name-resolution failures (a real hostname
  that cannot be resolved), never for IP literals or routing failures.
  *(must-have)*
- **Real failures surface faithfully.** For failures that are not
  fail-fast — the network or adapter cannot route the selected family
  (IPv6 disabled, no route, network unreachable) — the consumer receives
  the platform's real error, and common recognizable cases are mapped to
  typed `PingError`s so cross-platform code can branch on them. *(high)*
- **Hostnames are unchanged.** The library performs no DNS of its own;
  hostnames are handed to the platform, which resolves them (including
  DNS64-synthesized addresses on IPv6-only networks). A hostname ping that
  works today still works. *(regression guard)*
- **Cross-platform error consistency.** The same invalid input yields the
  same Dart-side error on iOS, Android, macOS, Linux, and Windows, even
  though the underlying native ping messages differ. *(must-have)*
- **Runtime behavior is preserved for equivalent calls.** A target whose
  family matches the selected family — e.g. IPv4 selected with an IPv4
  literal, or any hostname — pings exactly as it does today. The selector
  *parameter* changes shape (see Compatibility), but the ping behavior for
  an equivalent call does not. *(regression guard)*
- **The behavior is covered by automated tests** that do not require a
  live IPv6-only network (literal-vs-flag validation; error mapping for
  representative native outputs). *(high)*

## IPv6 — user stories §req:ipfamily-user-stories

- As a developer whose app runs on IPv6-only mobile data, I want pinging a
  host to behave the same as it does on Wi-Fi so that my diagnostics don't
  silently break on cellular.
- As a developer who selected IPv4 but passed an IPv6 literal (or selected
  IPv6 with an IPv4 literal), I want an immediate, clear error that tells me
  the selected family and the address disagree so that I fix my call instead
  of chasing a phantom "unknown host."
- As a cross-platform developer, I want the same error for the same
  mistake on every platform so that my shared error handling works
  everywhere despite differing native ping messages.
- As a developer diagnosing a real failure (IPv6 unavailable on the
  adapter, no route), I want an error that reflects the true cause so that
  I can tell "this network has no route for that family" apart from "that
  hostname doesn't exist."
- As an existing user, I want hostname pings and correctly-matched IP
  pings to behave exactly as they do today once I migrate to the new
  address-family selector, so that the breaking change is limited to how I
  name the family — not to how ping itself works.

## IPv6 — quality attributes §req:ipfamily-quality-attributes

- **Error honesty:** errors reflect the true failure mode; "unknown host"
  is reserved for real name-resolution failures.
- **Cross-platform consistency:** the same invalid input yields the same
  Dart-side error across all platforms; the library normalizes at the
  Dart boundary while staying thin underneath.
- **Thinness / native fidelity:** the library stays as close to native
  ping behavior as possible — no DNS of its own, no translation layer,
  valid targets passed straight through. Intervention is limited to
  up-front validation of incoherent combinations and faithful
  surfacing/mapping of native errors.
- **Compatibility:** the public Dart API shape (`Ping`,
  `PingData` / `PingResponse` / `PingSummary` / `PingError`) is preserved,
  **except** the address-family selector, which is intentionally
  redesigned. Replacing the ambiguous `ipv6` boolean with an explicit
  address-family selection is a deliberate **breaking change**, shipped
  with a major version bump and a migration note; the ambiguity of a
  boolean `false` (misread as "prefer IPv4 / dual-stack") is judged a
  worse long-term cost than a one-time migration. Any new error type is
  additive.
- **Testability:** mismatch and mislabeling behavior is verifiable via
  automated tests that do not depend on a live IPv6-only network.

## IPv6 — constraints §req:ipfamily-constraints

- The address family is an **exclusive** selection (IPv4-only or
  IPv6-only), matching the native `ping`/`ping6` (`-4`/`-6`) semantics the
  library already uses. The selector is an explicit address-family choice
  rather than a boolean flag, because a boolean `false` is reasonably
  misread as "prefer IPv4 / dual-stack" — the exact ambiguity behind #69.
- The library does **no DNS resolution of its own**; hostnames are handed
  to the platform. Up-front validation applies only to **literal IP**
  targets, whose family is determinable without resolution, and rejects a
  literal/flag mismatch in **both directions**.
- This work clarifies errors; it does **not** commit to adding IPv6
  support where a platform lacks it today (Windows IPv6 remains
  unsupported — the goal there is an honest error, not new capability).
- Any new typed error is **additive** to `PingError` / `ErrorType`;
  existing values keep their meaning. The error surface stays
  backward-compatible; the **address-family selector is the one
  deliberate breaking change** (major version bump, migration note), made
  to remove the boolean ambiguity at the heart of #69.
- Traceable to issue #69; relates to the refresh's error-mapping /
  parser-coverage goals (`§req:refresh-success-criteria`).

## IPv6 — priorities §req:ipfamily-priorities

- **Must-have:** stop mislabeling address-family and routing failures as
  "Unknown Host"; treat `ipv6` as an exclusive selector and fail fast with
  a clear, consistent, catchable error when a literal IP's family
  contradicts the flag; reserve `unknownHost` for genuine name-resolution
  failures.
- **High priority:** map common recognizable native failures (network
  unreachable / no route / family unavailable) to typed `PingError`s for
  cross-platform branching; automated tests for validation and error
  mapping.
- **Nice-to-have:** documentation of the exclusive-selector model and the
  IPv6-only-mobile-network (DNS64 / NAT64) behavior, so developers
  understand why hostnames can succeed where IP literals fail.

## IPv6 — open decisions §req:ipfamily-open-decisions

These surfaced during discovery and are deliberately deferred to `/plan`,
where mechanism is decided:

- **Platform scope.** #69 was reported on mobile data, so the iOS native
  Swift engine and/or Android are implicated, but the mislabeling
  principle applies to every engine (the core `dart_ping` process engine
  and `dart_ping_ios`). Which platforms actually exhibit the bug, and
  where each fix lands, is a design task. *(Was: "unsure / investigate".)*

---

# Interface selection (#72)

Add an optional way to control which network interface a ping originates
from. Driven by GitHub issue #72: a consumer wants to pick an interface
(the issue cites Linux's `ping -I`) and, ideally, discover which
interfaces are available. Additive feature on top of the existing
multi-platform `Ping` API.

## Interface — problem statement §req:interface-problem-statement

The target users are developers using `dart_ping` on machines with more
than one network path — a laptop on Wi-Fi and Ethernet at once, a device
with a VPN or tunnel interface alongside a physical one, or an embedded /
mobile system with both cellular and Wi-Fi radios.

Today `dart_ping` always pings over whatever interface the operating
system's default route selects. There is no way to say "send these pings
out of *this* interface" or "use *this* local source address." A
developer who needs to confirm reachability over a specific path cannot
do it through this package, even though the underlying system `ping`
binaries support it (e.g. `ping -I` on Linux). They are forced to drop
out of `dart_ping` and shell out to `ping` themselves, or change the
host's routing — both heavier than the task warrants.

This blocks several concrete needs the maintainer and issue reporter
called out, all variations of the same gap:

- **Multi-homed selection** — the device has several interfaces and the
  caller must pin pings to one specific NIC rather than accept the OS
  default.
- **Route / VPN verification** — confirm a host is reachable over (or
  explicitly bypassing) a VPN or tunnel by pinging from that interface.
- **Cellular vs. Wi-Fi** — on mobile/embedded hardware, test
  connectivity on a chosen radio independent of the current default
  route.
- **Diagnostics parity** — general network diagnostics that want the
  same `-I`-style control the system `ping` already offers.

A secondary part of the gap: even when a developer wants to pick an
interface, they often don't know the exact names/addresses available on
the current host, and those names differ per platform. So discovering the
candidate interfaces is part of the same problem, though a lesser part.

The problem is bounded to the desktop platforms `dart_ping` drives via a
native `ping` subprocess (Linux/Android, macOS, Windows). The iOS native
Swift engine does not expose interface binding today; pinning to an
interface there is a separate, larger piece of work and is explicitly
out of scope for this change.

## Interface — success criteria §req:interface-success-criteria

Observable, end-to-end outcomes a tester can demonstrate:

- **A ping can be pinned to an interface.** On Linux/Android and macOS, a
  developer can construct a `Ping` that specifies a network interface and
  observe — via the spawned command and the responses — that probes
  originate from the chosen interface rather than the OS default.
  *(must-have)*
- **Interface accepts a name or a source address.** The selection can be
  given either as an interface name (e.g. `eth0`, `en0`) or as a local
  source IP address (e.g. `192.168.1.5`), and both forms work where the
  platform supports them. *(must-have)*
- **Windows honors the source-address form.** On Windows, specifying a
  source IP address binds the ping to it. Passing a bare interface *name*
  on Windows — which the OS `ping` cannot bind by — produces a clear,
  catchable error rather than silently ignoring the request.
  *(must-have)*
- **Unsupported platforms fail loudly.** On iOS, supplying an interface
  or source selection throws an explicit "interface selection not
  supported" error, so a developer is never misled into thinking a
  selection took effect when it did not. *(must-have — mirrors how
  Windows rejects IPv6 today.)*
- **A bad interface surfaces an error, then closes.** If the chosen
  interface or source address does not exist or has no connectivity, the
  consumer receives a catchable error event on the stream and the stream
  then closes within bounded time — no hang. *(must-have — consistent
  with the #76 stream-lifecycle robustness work,
  `§req:robustness-success-criteria`.)*
- **Omitting the selection changes nothing.** When no interface/source is
  specified, behavior is byte-for-byte identical to today's: pings go out
  the OS default route and existing consumer code is unaffected.
  *(must-have — backward-compatibility guard.)*
- **Available interfaces can be listed.** A developer can call a helper
  that returns the network interfaces available on the current host
  (enough to identify and pass one back into a `Ping`), so an app can
  present a chooser or validate input. *(nice-to-have.)*

## Interface — user stories §req:interface-user-stories

- As a developer on a multi-homed machine, I want to tell `dart_ping`
  which interface to ping from so that I can verify reachability over a
  specific NIC instead of whatever the OS default route picks.
- As a developer validating a VPN or tunnel, I want to originate pings
  from that interface (or its source address) so that I can confirm a
  host is reachable over the intended path.
- As a developer on mobile/embedded hardware, I want to choose between
  cellular and Wi-Fi when pinging so that I can test each radio
  independently of the current default route.
- As a cross-platform developer, I want to pass either an interface name
  or a source address and have it work the same way on Linux/Android and
  macOS so that my shared code is predictable.
- As a Windows developer, I want a clear error when I pass an interface
  name that Windows can't bind by, so that I switch to a source address
  instead of silently pinging the wrong interface.
- As an iOS developer, I want a clear "not supported" error if I try to
  select an interface so that I'm not misled into thinking it worked.
- As a developer who doesn't know the host's interfaces, I want to list
  the available ones so that I can show a picker or validate the value I
  pass in.
- As an existing `dart_ping` user, I want pings without an interface
  argument to behave exactly as they do today so that this addition is
  invisible to my working code.

## Interface — quality attributes §req:interface-quality-attributes

- **Compatibility:** the feature is additive and optional — the existing
  public `Ping` API and the `PingData` / `PingResponse` / `PingSummary` /
  `PingError` shapes are unchanged for callers who don't use it. A
  non-breaking, minor-version addition to `dart_ping`.
- **Cross-platform predictability:** the same selection value behaves the
  same way across the supported desktop platforms wherever the platform
  allows it; where a platform genuinely cannot (Windows + interface name,
  iOS entirely), the difference surfaces as a clear error rather than
  silent divergence.
- **Reliability:** a selection that can't be honored never leaves the
  stream hanging — it surfaces a catchable error and the stream closes,
  consistent with the broader stream-lifecycle guarantees.
- **Discoverability:** error messages name the problem in the user's
  terms (e.g. interface name vs. source address, platform not supported)
  so a developer can correct the call without reading the source.
- **Testability:** the command produced for a given selection, the
  per-platform rejections, and the bad-interface error path are
  verifiable via automated tests where feasible (e.g. asserting the
  spawned command), without requiring specific live hardware.

## Interface — constraints §req:interface-constraints

- Scope is the desktop platforms `dart_ping` drives via a native `ping`
  subprocess: **Linux/Android, macOS, and Windows**. **iOS is out of
  scope** and rejects the selection with a clear error.
- Selection accepts **either an interface name or a local source
  address**. On platforms whose `ping` cannot bind by name (Windows,
  which binds only by source address), the name form is rejected with a
  clear error rather than approximated.
- The change is **additive and backward-compatible**: a new optional
  parameter (plus the optional listing helper). Omitting it preserves
  current behavior. Ships as a **minor version** of `dart_ping`.
- The exact parameter name/shape, the per-platform `ping` flags (Linux
  `-I`, macOS `-b` / `-S`, Windows `-S`), name↔address resolution, and
  the listing helper's signature are **design decisions for
  `/symphonize:plan`**, not fixed here.
- Bad-interface handling reuses the stream error channel and termination
  guarantees from `§req:robustness-*`; this feature does not introduce a
  new failure-reporting mechanism.

## Interface — priorities §req:interface-priorities

- **Must-have:** an optional interface/source selection on Linux/Android
  and macOS, accepting a name or a source address; Windows honoring the
  source-address form and clearly rejecting bare names; iOS clearly
  rejecting the selection; a bad selection surfacing a catchable error
  and closing the stream; and no change to behavior when the selection is
  omitted.
- **High priority:** consistent, well-worded errors across the platform
  differences so cross-platform callers can react predictably; automated
  tests for the produced command and the rejection/error paths.
- **Nice-to-have:** the helper that enumerates the host's available
  network interfaces for use in a picker or for input validation.

---

# Concurrent-ping isolation (#70)

A reported correctness defect: when several `Ping` instances run at the
same time, they report the same round-trip result instead of each host's
own. First observed on Android, but the requirement is to guarantee
isolation on every platform.

## Concurrent pings — problem statement §req:concurrent-problem-statement

The target users are developers who ping **several hosts at once** —
typically by creating one `Ping` per host and awaiting them together, the
canonical pattern for latency dashboards, server pickers, "fastest
mirror" selection, and connectivity sweeps:

```dart
var domains = ['154.16.146.45', '187.188.169.169'];
var pings = domains.map((e) => Ping(e, count: 1).stream.first).toList();
var results = await Future.wait(pings);
```

A user (issue #70, on Android) reports that the concurrent results are
**cross-contaminated**: each response carries the correct destination IP,
but the round-trip time is identical across hosts —
`time:176.0 ms` for both `154.16.146.45` and `187.188.169.169`. Pinging
the same hosts **one at a time** returns the correct, distinct
times (`170.0 ms` and `236.0 ms`). So the data is right when pings run
sequentially and wrong when they overlap.

Current behavior fails these users because the failure is **silent and
plausible**: no error is thrown, the shape of the result is valid, and the
IPs look right — so the caller has no signal that the timings (and
possibly TTL) are wrong. Code that picks the "fastest" host, charts
latency, or gates on a threshold then acts on fabricated numbers. Anyone
pinging more than one host concurrently is exposed, and concurrent
multi-host pinging is a common, expected use of the library rather than an
exotic edge case.

The root cause is not yet established — each `Ping` instance already owns
its own OS process and stream, so there is no obvious shared state — and
identifying it is left to `/plan`. It is also not yet confirmed whether the
defect still reproduces on the current release (the report predates recent
internal changes). This document captures the **observable problem** the
user experiences; the cause and the platforms actually affected are
solution-space questions for `/plan`.

## Concurrent pings — success criteria §req:concurrent-success-criteria

Observable, verifiable outcomes a tester can demonstrate against the
public API:

- **The defect is first reproduced (or shown already fixed).** A
  test/repro that overlaps multiple `Ping` streams demonstrates the
  cross-contamination against the current release — or establishes that it
  no longer occurs. This gate sets the priority of the remaining
  criteria. *(must-have — the confirm-then-decide step)*
- **Concurrent pings return each host's own results.** When N `Ping`
  instances to distinct hosts run at the same time, each stream's
  responses carry that host's own round-trip time, TTL, and sequence —
  matching what the same host returns when pinged alone. No field is
  copied from a sibling ping. *(must-have)*
- **Isolation holds on every platform.** The guarantee applies wherever
  `dart_ping` runs — Android, Linux, macOS, and Windows (which share the
  process-based engine) — and on iOS. Concurrent `Ping` instances are
  fully independent everywhere. *(must-have)*
- **Per-host summaries and error lists stay separate.** Each concurrent
  run's summary (transmitted/received/time) and per-run error list reflect
  only that run; errors or counts from one ping never appear in another's
  summary. *(high)*
- **Sequential behavior is unchanged.** Pinging hosts one at a time still
  returns the same correct, distinct results as today. *(must-have —
  regression guard)*
- **An automated test guards isolation, with no live network.** A test
  runnable under `dart test` overlaps multiple ping streams and **fails
  if results cross-contaminate**, so a future regression is caught
  offline rather than only on a device. *(must-have)*

## Concurrent pings — user stories §req:concurrent-user-stories

- As a developer pinging a list of hosts at once to find the fastest, I
  want each result to reflect its own host's latency so that I pick the
  genuinely closest server instead of one chosen from duplicated numbers.
- As a developer building a latency dashboard, I want concurrent pings to
  report independent round-trip times so that my chart shows real
  per-host values rather than one value smeared across every row.
- As a developer running a connectivity sweep, I want each host's
  reachability and timing to be its own so that a single slow or failing
  host does not silently mask or impersonate the others.
- As an existing user who pings hosts one at a time, I want that path to
  keep returning the same correct results so that this fix changes nothing
  for sequential callers.
- As a maintainer, I want an automated test that fails when concurrent
  results bleed together so that this class of bug cannot quietly return.

## Concurrent pings — quality attributes §req:concurrent-quality-attributes

- **Correctness:** concurrent `Ping` instances are fully independent;
  no response, timing, TTL, summary, or error from one ping appears in
  another. This is the core guarantee.
- **Compatibility:** the public API is unchanged — the `Ping` interface
  and the `PingData` / `PingResponse` / `PingSummary` / `PingError`
  shapes stay the same. Existing concurrent and sequential call sites keep
  working without edits; correct code simply starts returning correct
  data.
- **Cross-platform consistency:** the isolation guarantee is uniform
  across Android, Linux, macOS, Windows, and iOS.
- **Testability:** isolation is verifiable by an automated test that
  fails on cross-contamination and runs without a live network.

## Concurrent pings — constraints §req:concurrent-constraints

- The public Dart API stays unchanged; this is a correctness fix, not a
  feature.
- Scope is the cross-contamination defect and the guarantee that
  concurrent `Ping` instances are independent — not new concurrency
  features (e.g. no built-in multi-host helper is required).
- The fix and its test must not depend on a live network or a physical
  device to validate the isolation logic.
- Surfaced by, and traceable to, issue #70; relates to the core
  process-based engine (`§spec:` to be assigned in `/plan`).

## Concurrent pings — priorities §req:concurrent-priorities

- **First gate (confirm-then-decide):** reproduce the defect on the
  current release, or establish that it is already fixed. The outcome sets
  how urgent the rest is.
- **Must-have (if it reproduces):** concurrent `Ping` instances return
  each host's own results on every platform, sequential behavior is
  unchanged, and an offline automated test guards against regression.
- **High priority:** keep per-host summaries and error lists separate
  under concurrency.
- **Nice-to-have:** none beyond the above — this is a focused correctness
  fix.

---

# Summary statistics (#63)

Surface richer round-trip statistics in the ping result, and make them
available both as a final run summary and as live running figures during a
run. Driven by GitHub issue #63: a consumer of the `vernet` app asked to
show the round-trip `min / avg / max / stddev` values that the native
`ping` already prints at the end of a session (screenshots for macOS and
Linux are attached to the issue). The work is delivered through a
from-scratch redesign of the stream's event/data classes, ridden in on the
already-unreleased breaking majors.

## Statistics — problem statement §req:stats-problem-statement

The target users are developers using `dart_ping` for latency measurement
and network diagnostics — latency dashboards, "fastest host" pickers,
connectivity sweeps, and traceroute-style tools.

The native `ping` binary prints a round-trip summary at the end of every
session (`round-trip min/avg/max/stddev = …` on macOS/Linux; Minimum /
Maximum / Average on Windows), and that is exactly the information a
diagnostics UI wants to show. `dart_ping` discards it. Its `PingSummary`
exposes only `transmitted`, `received`, an optional total `time`, and the
error list — so a developer who wants min / avg / max / stddev, jitter, or
a packet-loss percentage has to reconstruct them by hand from the
per-probe response stream. min / max are easy; **stddev and jitter are
not**, and getting them right (which samples to include, how to define
jitter) is exactly the kind of thing a library should do once, correctly,
for everyone.

Three things make the do-it-yourself path worse than it looks:

- **The raw material is lossy.** Per-probe `PingResponse.time` is a
  `Duration` with sub-millisecond resolution in memory, but its
  serialized form (`toMap`) truncates to whole milliseconds — so a
  consumer who computes stats from serialized data loses the precision
  that makes stddev/jitter meaningful for fast local links.
- **There is no running view.** Stats only make sense at the end today;
  there is no way to watch min / avg / max / jitter evolve while a long
  run is in progress, which is what a live dashboard wants.
- **The event shape resists extension.** A stream event is a single
  `PingData` with three nullable fields (`response` / `summary` /
  `error`), and consumers detect end-of-run by checking
  `summary != null`. That idiom makes "a summary-so-far on every probe"
  impossible to add without breaking the very signal consumers rely on.

The reporter's underlying need is simple — *"show me the stats my OS
already computes"* — but satisfying it well (cross-platform, precise,
live, and on iOS too, where there is no native summary line at all) is
what motivates the redesign rather than a field bolt-on.

## Statistics — success criteria §req:stats-success-criteria

Observable, verifiable outcomes a tester can demonstrate against the
public API:

- **The summary exposes the full statistic set.** A completed run reports
  round-trip **min, avg, max, and stddev**, a **jitter** figure, and a
  **packet-loss percentage**, in addition to the existing
  transmitted / received / total-time / errors. *(must-have)*
- **The same set is available on every platform.** Linux/Android, macOS,
  Windows, and iOS all report the complete set — including stddev on
  Windows (whose native `ping` omits it) and every figure on iOS (whose
  native engine emits no summary line). Where a platform's native output
  is missing a value, the library fills it by computing from the per-probe
  round-trip times; where the native value is present it is preferred.
  *(must-have)*
- **Live stats are observable during a run.** While a run is in progress,
  a consumer can observe the running statistics (min / avg / max / stddev /
  jitter / loss so far) update as each probe arrives — not only once at the
  end. *(must-have)*
- **The end of a run is unambiguous.** A consumer can tell a per-probe
  event, an error event, and the terminal run-summary event apart without
  guessing from which fields happen to be null, and the terminal summary is
  identifiable as the final event of the run. *(must-have)*
- **Packet loss is consistent with the counts.** The reported loss
  percentage always equals the loss implied by `transmitted` and
  `received` (it is a derived view of them, not an independently stored
  number that can drift). *(must-have)*
- **Zero-reply runs report honestly.** When a run receives no replies
  (100% loss), the round-trip statistics (min / avg / max / stddev /
  jitter) are reported as absent/undefined rather than as fabricated
  zeros, while loss is 100% and received is 0. *(must-have)*
- **Sub-millisecond precision is preserved.** The round-trip statistics
  retain the resolution the platform provides (sub-millisecond where the
  native tool reports it); they are not silently truncated to whole
  milliseconds on the way to the consumer or through serialization.
  *(high)*
- **Jitter means probe-to-probe variation.** The jitter figure is the
  mean of the absolute differences between consecutive successful probe
  round-trip times, and this definition is documented so consumers know
  what they are charting. *(high)*
- **Existing result information is preserved.** transmitted, received,
  total `time` (where the platform reports it), the per-run error list,
  and per-probe seq / ttl / time / ip all remain available after the
  redesign. *(must-have — no information is lost in the reshape.)*
- **The behavior is covered by automated tests** that run under
  `dart test` without a live network — verifying the computed statistics
  for representative per-probe inputs, the zero-reply case, the
  native-vs-computed fill, and that the terminal event is distinguishable.
  *(high)*

## Statistics — user stories §req:stats-user-stories

- As a developer building a latency dashboard, I want the run summary to
  give me round-trip min / avg / max / stddev and jitter directly so that
  I can display them without reimplementing the math.
- As a developer comparing hosts, I want a packet-loss percentage in the
  summary so that I can rank or gate on reliability as well as latency.
- As a developer running long or continuous pings, I want to watch the
  statistics update live as probes arrive so that my UI reflects current
  conditions instead of only a final number.
- As a cross-platform developer, I want the same statistics on Windows and
  iOS as on Linux/macOS — including stddev and jitter — so that my shared
  diagnostics code shows the same columns everywhere.
- As a developer consuming the stream, I want to tell probe, error, and
  end-of-run events apart explicitly so that my handling code is clear and
  doesn't break when new fields appear.
- As a developer measuring a fast local link, I want sub-millisecond
  precision retained in the statistics so that stddev and jitter are
  meaningful rather than rounded to zero.
- As a developer whose run gets no replies, I want the latency statistics
  to be clearly "not available" rather than zero so that I don't chart a
  misleading 0 ms for an unreachable host.

## Statistics — quality attributes §req:stats-quality-attributes

- **Cross-platform consistency:** the same statistic set is reported on
  every platform, normalized at the Dart boundary, despite differing
  native summary formats (and iOS having none).
- **Native fidelity where it exists:** where a platform's native `ping`
  reports a statistic, that value is preferred; the library only computes
  the figures the platform does not provide, staying as close to native
  numbers as the cross-platform goal allows.
- **Precision:** statistics retain the resolution the native tool
  provides; serialization does not truncate round-trip values to whole
  milliseconds (the current `toMap` truncation is corrected as part of
  this work).
- **Clarity of the event contract:** the stream's event types make the
  kind of each event explicit, so consumers branch on event type rather
  than on which nullable field is populated.
- **Compatibility:** this is a **breaking change**, but it is folded into
  the already-unreleased breaking majors (`dart_ping` 10.0.0,
  `dart_ping_ios` 6.0.0) — see Constraints. No additional break is imposed
  beyond the one the next release already carries.
- **Testability:** the statistic computations and the event contract are
  verifiable via offline automated tests without a live network or a
  physical device.

## Statistics — constraints §req:stats-constraints

- **The delivery vehicle is a from-scratch redesign of the stream's
  event/data classes.** The current single-`PingData`-with-nullable-fields
  shape is replaced by an explicit, discriminated set of stream events
  (a probe response, a probe error, and a terminal run summary), and the
  round-trip statistics are carried by a single reusable value object
  (round-trip min / avg / max / stddev / jitter / sample count) that can
  be computed incrementally. This is the design judged most sensible if
  the stream were built today; #63 is the occasion to adopt it because the
  next release is already breaking.
- **Packet loss is a derived view, not stored state** — computed from
  `transmitted` and `received` on read, so it cannot drift from the
  counts and adds no redundant serialized field.
- **Jitter is defined** as the mean of the absolute differences between
  consecutive successful probe round-trip times (RFC 3550-style
  interarrival variation), computed over received replies only.
- **Round-trip statistics are computed over successful replies only**
  (timed-out / errored probes contribute to loss and counts, not to
  min / avg / max / stddev / jitter).
- **Version / release:** the redesign ships in the already-unreleased
  `dart_ping` **10.0.0** and `dart_ping_ios` **6.0.0** majors. The
  maintainer is consolidating all changes since the last published
  release into these majors, so the breaking event/data reshape is
  absorbed by a break the release already carries.
- **This revises the API-stability stance of the earlier work areas.**
  Sections 1–6 above each promise the `PingData` / `PingResponse` /
  `PingSummary` shapes stay unchanged; those promises were scoped to the
  same unreleased 10.0.0 / 6.0.0 window and are **superseded** by this
  redesign — the public event/data shape changes once, here, as part of
  that major, rather than each area preserving the old shape.
- iOS parity is **in scope**: the native Swift engine surfaces the same
  statistic set (computed from per-probe times, as it has no native
  summary line).
- Traceable to issue #63; relates to the refresh's serialization-precision
  and test-coverage goals (`§req:refresh-success-criteria`).

## Statistics — priorities §req:stats-priorities

- **Must-have:** the run summary reports round-trip min / avg / max /
  stddev, jitter, and packet-loss %, with the same set on every platform
  (including Windows stddev and iOS); live running stats observable during
  a run; an unambiguous, explicitly-typed terminal event; zero-reply runs
  reporting absent latency stats with 100% loss; and no existing result
  information lost in the reshape.
- **High priority:** sub-millisecond precision preserved end-to-end
  (including the serialization-truncation fix); documented jitter
  definition; offline automated tests for the computations, the
  native-vs-computed fill, the zero-reply case, and the event contract.
- **Nice-to-have:** none beyond the above — scope is the statistics plus
  the event redesign that makes them clean to deliver.

## Statistics — open decisions §req:stats-open-decisions

Surfaced during discovery and deferred to `/symphonize:plan`, where
mechanism is decided:

- **Exact event/value-object shapes and names** — the concrete sealed
  event hierarchy, the round-trip-stats value-object API, and how a
  running stats snapshot rides each probe event (an attached field, a
  separate periodic event, or both) are design choices for `/plan`,
  constrained by the observable outcomes above.
- **Native-vs-computed precedence and tolerance** — when a platform
  reports a native value *and* the library can compute one, which wins and
  whether any consistency check / tolerance is applied (the success
  criteria require "the full set, consistent"; the exact reconciliation is
  a design detail).
- **Serialization format for the new shape** — the JSON/map
  representation of the redesigned events and the precision-preserving
  encoding of round-trip values (replacing the whole-millisecond
  truncation) are for `/plan`.
- **iOS surfacing mechanism** — how the native Swift engine exposes the
  per-probe data the stats are computed from, over the method channel, is
  a design task for `/plan`.

---

# NAT64 / IPv6-only IP-literal reachability (#52)

A capability fix for `dart_ping_ios` (and, in principle, any platform
that can synthesize): make pinging a bare IPv4 literal **succeed** on an
IPv6-only cellular network, where today it fails outright. Driven by
GitHub issue #52. This **extends the scope boundary of #69**
(`§req:ipfamily-*`): #69 made the failure's *error* honest but
deliberately declined to make the ping *work*, treating an IPv4 literal
on an IPv6-only network as a legitimate no-route. #52 revisits that
boundary — the evidence shows the ping can be made to succeed via the
platform's NAT64 address synthesis, so the user-visible failure is
avoidable, not inevitable.

## NAT64 — problem statement §req:nat64-problem-statement

The target users are Flutter/Dart developers using `dart_ping` /
`dart_ping_ios` for ping diagnostics in apps that run on mobile devices —
most acutely on iOS.

The reported problem (#52): on iOS, on a **cellular / mobile-data**
connection, pinging a **literal IPv4 address** (e.g. `13.35.27.1`) fails
immediately with `unknownHost`, followed downstream by a timeout / "no
stream event." The **same literal pings fine over Wi-Fi**, and pinging
the target **by hostname succeeds even on the same cellular connection**.
The failure reproduces on **physical hardware** (reported on iPhone 14
Pro / Telstra 5G in Australia, and on 5G/LTE with US carriers) but **not
on the iOS simulator**. Multiple developers report it.

Underneath, modern carriers increasingly run **IPv6-only access networks
with NAT64 + DNS64** (464XLAT). On such a network, a *hostname* is
resolved by the system's DNS64, which hands back a **synthesized IPv6
(NAT64) address** that routes to the IPv4 destination — so hostname pings
work. A **bare IPv4 literal**, however, is handed straight to the network
stack with no synthesis; there is no native IPv4 route, so the ping has
nowhere to go and fails. Apple's own `SimplePing` sample (the lineage of
the iOS engine) exhibits exactly this symptom unless it is made
NAT64-aware.

The tell that this is **fixable, not an immovable carrier wall**: on the
*same phone and the same network*, **third-party "Ping" apps succeed**
pinging the same IPv4 literal, and **Apple's updated `SimplePing`
succeeds** once it synthesizes the NAT64 address. Apple documents the
mechanism in *"Supporting IPv6 DNS64/NAT64 Networks"*: feed the IPv4
literal through the system resolver (`getaddrinfo`), which on an
IPv6-only network returns a **synthesized IPv6 address** that routes.
Apps that do this reach the host; code that passes the raw IPv4 literal
to the socket does not.

This is where #52 diverges from #69. #69 closed the "hostname works, IP
literal fails with *Unknown Host*" signature by making the **error
honest** — an address-family / no-route failure is now reported as such,
not as a phantom name-resolution failure — and its spec explicitly says
the IPv4 literal "legitimately has no route" and that the work is
"honesty, not new capability" (`§req:ipfamily-constraints`,
`§spec:address-family-error-honesty`). #52's evidence contradicts the
"legitimately has no route" premise: the route *can* be obtained via
synthesis. The remaining gap, after #69, is that an affected user still
**cannot ping an IP literal on mobile data at all** — they get an honest
error instead of a misleading one, but the ping still does not work, when
every other ping tool on the device makes it work.

The problem is **growing** (carriers keep migrating to IPv6-only cores),
**intermittent** (only on certain cellular networks), and **expensive to
diagnose** — it cannot be reproduced on a developer's Wi-Fi or in the
simulator, and it is easy to misattribute to the carrier. For affected
users it is effectively a **total loss of IP-literal ping on mobile
data**.

## NAT64 — success criteria §req:nat64-success-criteria

Observable, verifiable outcomes:

- **The IPv4 literal pings successfully on an IPv6-only cellular
  network.** On a network where the literal fails today, pinging it
  produces the **same observable result as pinging it over Wi-Fi** —
  responses with round-trip times and a normal summary — matching what
  third-party ping apps achieve on the same device. *(must-have)*
- **Controlled by an explicit option, enabled by default.** There is a
  named, documented option that turns NAT64 / IPv6-only literal handling
  on. With defaults, an affected user's existing call **starts working
  with no code change**; a caller can **disable** the option to get the
  prior raw pass-through behavior. Because not all platforms can
  synthesize, the option's *effect* is platform-dependent (see
  Constraints), but its presence and default are consistent. *(must-have)*
- **When synthesis cannot help, the error stays honest.** On a
  platform/network where the literal genuinely cannot be made reachable
  (synthesis unsupported or unavailable, or a real no-route), the consumer
  receives the honest typed error from #69 (no-route / address-family) —
  **never a phantom `unknownHost`, never a silent hang/timeout**
  (`§req:ipfamily-success-criteria` — "real failures surface
  faithfully"). *(must-have)*
- **The user-facing address family is unchanged by synthesis.** The
  caller still selects IPv4 and pings an IPv4 literal; that the library
  reaches it via a synthesized IPv6 / NAT64 address underneath is an
  implementation detail and does not change the result shape or the
  selected `IpVersion`. *(must-have)*
- **Hostnames and Wi-Fi behavior are unchanged.** A hostname ping
  (including a DNS64-synthesized one) and any ping that already works over
  Wi-Fi or a dual-stack network behaves identically. *(regression guard)*
- **No regression to #69 error honesty.** Turning the option off, or
  hitting a genuinely unreachable target, reproduces #69's honest typed
  errors exactly — including the literal-vs-family `ArgumentError`
  (`§spec:address-family-mismatch-validation`). *(regression guard)*
- **The behavior is covered by automated tests** that do not require a
  live IPv6-only cellular network — the synthesis decision and the
  option's on/off behavior are verifiable offline; the live end-to-end leg
  is hand- / on-device-verified, as with #69. *(high)*

## NAT64 — user stories §req:nat64-user-stories

- As a developer whose users are on IPv6-only mobile data, I want pinging
  an IPv4 literal to succeed the way it does over Wi-Fi — and the way
  other ping apps do on the same phone — so my diagnostics don't silently
  break on cellular.
- As a developer, I want this handled **by default** so the fix reaches my
  existing code with no change, but I want a documented switch to turn it
  **off** if I need raw pass-through behavior.
- As a developer on a network or platform where the literal truly cannot
  be reached, I want the honest "no route for this family" error from #69
  — not a phantom "unknown host" and not a five-second hang.
- As a cross-platform developer, I want the same call to behave
  consistently: where a platform can synthesize, the literal pings; where
  it cannot, I get the same honest typed error everywhere, and the
  difference is documented rather than surprising.
- As an existing user who relies on current behavior, I want hostname
  pings, Wi-Fi pings, and already-matching IP pings unchanged — and an
  opt-out — so the only thing that changes is that a previously-failing
  cellular IP-literal ping now works.

## NAT64 — quality attributes §req:nat64-quality-attributes

- **Reachability parity:** an IPv4 literal that other ping tools can reach
  on a given phone and network should be reachable through `dart_ping`
  too.
- **Backward-compatible, default-on:** the option defaults to enabled so
  affected users are fixed without code changes, while existing
  well-behaved calls are unchanged and an opt-out restores prior behavior.
- **Error honesty preserved:** synthesis is attempted first; a genuine
  failure still surfaces the honest #69 typed error — never `unknownHost`,
  never a hang (`§req:ipfamily-quality-attributes` — error honesty).
- **Thinness / native fidelity:** the library leans on the **platform's
  own** NAT64 synthesis (on iOS, the `getaddrinfo` path Apple documents),
  not a hand-rolled DNS or NAT layer — it adds the synthesis hook the
  platform expects and otherwise stays thin.
- **Cross-platform consistency:** the same call yields the same Dart-side
  outcome given the platform's capability; capability differences are
  documented, not surprising.
- **Testability:** the option and the synthesis decision are verifiable
  without a live IPv6-only network; the live leg is on-device verified.

## NAT64 — constraints §req:nat64-constraints

- **Capability is platform-dependent and gated by an explicit option.**
  Not every platform exposes NAT64 address synthesis, so the behavior is
  controlled by an explicit option that **defaults to enabled** and is a
  no-op where the platform cannot synthesize. **iOS is the reported and
  primary target**; which other platforms participate is an open decision
  for `/plan`.
- **Stay thin — use the platform mechanism.** Prefer the platform's
  documented synthesis path (on iOS, the `getaddrinfo` / NAT64 approach in
  Apple's *"Supporting IPv6 DNS64/NAT64 Networks"*) over a custom
  resolver. The library performs **no DNS of its own**.
- **Do not regress #69.** The honest-error behavior and the exclusive
  `IpVersion` selector from #69 remain. Synthesis sits **in front of**
  them: it converts a previously-unreachable IPv4 literal into a reachable
  one where possible, and otherwise yields the **same** honest typed
  error. The literal-vs-family `ArgumentError` is unaffected.
- **The user-facing family selection is unchanged.** Synthesis is an
  under-the-hood route to the IPv4 target, not a switch of the caller's
  selected address family.
- **Not reproducible in CI.** Like #69, a live IPv6-only cellular network
  is unavailable to hosted runners; **on-device verification** is required
  for the end-to-end leg, while the option/decision logic is covered by
  offline tests.
- Traceable to issue #52; **extends / revises** the scope boundary of #69
  (`§req:ipfamily-constraints` — "honesty, not new capability";
  `§spec:address-family-error-honesty` — "scope boundary — honesty, not
  new capability").

## NAT64 — priorities §req:nat64-priorities

- **Must-have:** IPv4-literal pings **succeed** on IPv6-only cellular
  where the platform can synthesize, **on iOS at minimum**; behavior
  controlled by an explicit, **default-enabled** option; the honest #69
  error retained when synthesis cannot help; no regression to hostname or
  Wi-Fi pings.
- **High priority:** cross-platform consistency and clear documentation of
  which platforms synthesize; offline automated tests for the option and
  the synthesis decision.
- **Nice-to-have:** extending synthesis beyond iOS where feasible;
  documentation of NAT64 / DNS64 explaining why hostnames succeed where
  bare IP literals historically failed.

## NAT64 — open decisions §req:nat64-open-decisions

Surfaced during discovery and deferred to `/symphonize:plan`, where
mechanism is decided:

- **Platform reach.** Which platforms beyond iOS actually gain synthesis
  (Android's stack behavior on NAT64; whether desktop is in scope) is a
  design task — the requirement is framed cross-platform but iOS is the
  one confirmed target.
- **Option shape, name, and default semantics.** The concrete name and
  type of the explicit option, and exactly what "enabled by default"
  means per platform (a no-op where unsupported vs. an error), are design
  choices.
- **iOS synthesis mechanism.** How the native Swift engine performs
  synthesis (e.g. `getaddrinfo` on the literal with the appropriate flags,
  and handling of the returned synthesized `sockaddr`) and where it sits
  relative to the existing #69 resolve/send path.
- **Fallback ordering.** Precisely when synthesis is attempted versus when
  it yields to the honest #69 error (e.g. only when the selected family is
  IPv4, the target is an IPv4 literal, and the network presents as
  IPv6-only), and whether any of this is observable to the caller.
- **Interaction with the `IpVersion` selector and #69 validation.**
  Confirming that synthesis does not change the validated family or
  disturb the literal-vs-family `ArgumentError`
  (`§spec:address-family-mismatch-validation`).

---

# Windows interface-listing round-trip contract (#85)

A clarification, not a new feature. The interface-selection work (#72,
`§req:interface-*`) shipped a nice-to-have helper that lists the host's
network interfaces so a developer can "pass one back into a `Ping`." An
automated test read that promise as *every interface name round-trips
into a `Ping` on every platform* — an assumption the package itself
contradicts on Windows. The contradiction stayed hidden until the
cross-OS CI matrix ran the core suite on a real Windows host, where it
turned the Windows check red. This area makes the round-trip contract
honest per platform.

## Windows round-trip — problem statement §req:windows-roundtrip-problem-statement

The affected party here is the **maintainer** (and any contributor whose
PR is blocked by a red gate), and secondarily the **cross-platform
developer** who relies on the interface-listing helper's promise.

The interface-selection feature (#72) established two facts that are both
correct and both already documented in `§req:interface-success-criteria`:

- The listing helper returns the host's interfaces, "enough to identify
  and pass one back into a `Ping`."
- On Windows, the OS `ping` binds **only by source address** (`-S
  <address>`), never by interface name, so passing a **bare interface
  name** on Windows produces a clear, catchable error rather than silently
  pinging the default route.

A test encoded a *stronger* reading of the first fact than the second
allows: that every listed interface's **name** can be fed back into
`Ping(interface: name)` and construct without throwing, on **every**
platform. That holds on Linux/Android and macOS, whose `ping` binds by
name. It is **false on Windows** — by the package's own deliberate
design, a bare name is rejected.

The contradiction was invisible while CI gated only PRs to `main` on the
existing matrix; it surfaced once the core suite ran on an actual Windows
runner (the cross-OS matrix from #77, extended to PRs targeting `develop`
in #85). The Windows runner reports a named NIC (`"Ethernet 3"`); the
round-trip test feeds that name back into a Windows `Ping`, which
**correctly** throws `UnimplementedError` ("Windows ping binds only by
source address, not by interface name…"), and the test fails with
`195 tests passed, 1 failed`.

The user-visible problem is therefore a **red Windows CI check that
blocks merges**, caused not by wrong Windows behavior but by a test
asserting a guarantee the package never offered on Windows. The defect is
in the *contract/expectation*, not in Windows ping behavior. Left
unaddressed it is both **frequent** (every PR re-runs the gate) and
**expensive** (a red required check stops the merge queue and erodes
trust in the matrix), while masking the fact that Windows is, in truth,
behaving exactly as specified.

## Windows round-trip — success criteria §req:windows-roundtrip-success-criteria

Observable, verifiable outcomes:

- **The Windows core CI check passes.** The `core (windows-latest)` job
  goes green on a host that reports named NICs, so the cross-OS gate is
  green on Linux, Windows, and macOS together. *(must-have)*
- **The round-trip promise is honest per platform.** A listed interface's
  **source address** round-trips into a `Ping` — constructs without
  throwing — on **every** supported desktop platform. A listed interface's
  **name** round-trips **only** where the OS binds by name (Linux/Android,
  macOS); on Windows, passing a listed **name** is rejected with the
  clear, catchable error already specified, and passing the listed
  **address** works. *(must-have)*
- **Windows runtime behavior is unchanged.** Source-address selection
  still binds on Windows; a bare interface name is still rejected loudly
  (never a silent default-route ping). No platform's runtime behavior
  changes — only the contract and the test's expectation do. *(must-have —
  consistency with `§req:interface-success-criteria`.)*
- **The check is deterministic across runners.** The round-trip is
  verified by automated tests that pass on a real Windows host and do
  **not** depend on which interface names or addresses a particular runner
  happens to report. *(must-have — the original failure was runner-NIC
  dependent.)*

## Windows round-trip — user stories §req:windows-roundtrip-user-stories

- As a maintainer, I want the Windows CI check to pass so that merges
  aren't blocked by a test asserting behavior the package intentionally
  does not have.
- As a cross-platform developer using the listing helper, I want "pass one
  back into a `Ping`" to be true everywhere — I can rely on a listed
  interface's **source address** round-tripping on any desktop platform,
  and I understand the **name** works only where the OS binds by name.
- As a Windows developer enumerating interfaces, I want a clear, working
  path (select by the source address) and a clear error if I pass a name,
  rather than a confusing CI failure or a silent wrong-interface ping.

## Windows round-trip — quality attributes §req:windows-roundtrip-quality-attributes

- **Cross-platform honesty:** the documented round-trip contract matches
  actual per-platform behavior; there is no "green everywhere" claim that
  is false on one OS (`§req:interface-quality-attributes` —
  cross-platform predictability).
- **Determinism:** the verifying test does not depend on host-specific NIC
  names or addresses, so it is reproducible on any runner.
- **Backward compatibility:** no change to the public API and no change to
  runtime behavior on Linux/Android, macOS, or Windows — only the contract
  wording and the test expectation change.
- **Testability:** the corrected round-trip is exercised on a real Windows
  host in CI, so the same contradiction cannot silently return.

## Windows round-trip — constraints §req:windows-roundtrip-constraints

- **Refinement, not new capability.** This refines
  `§req:interface-success-criteria` ("Available interfaces can be listed"
  and "Windows honors the source-address form"). Windows keeps **rejecting
  bare names**; the fix corrects the contract and the test, it does not add
  Windows name binding.
- **No new public API, no behavior change** on any platform. Scope is the
  listing↔selection round-trip contract and the tests that assert it.
- **Decided in discovery:** the round-trippable handle is the source
  **address** universally; the **name** only where the OS binds by name.
  Making Windows resolve a name → source address (so names round-trip
  everywhere) is **explicitly out of scope**.
- **Traceability:** surfaced by issue **#85** (the CI work that ran the
  core suite on a Windows host); relates to the cross-OS matrix (#77) and
  interface selection (#72). The separate Windows IPv6 gap (#71) is **not**
  in scope.

## Windows round-trip — priorities §req:windows-roundtrip-priorities

- **Must-have:** the Windows core CI check green; an honest per-platform
  round-trip contract (address everywhere, name only where bound by name);
  Windows name-rejection / address-acceptance unchanged; a deterministic
  test independent of host NIC names and addresses.
- **Nice-to-have:** a documentation note on the listing helper explaining
  that on Windows you pass back a listed interface's **source address**,
  not its name.

---

# CI on PRs to `develop`

## CI on develop — problem statement §req:ci-develop-problem-statement

The user is the maintainer of this two-package repository
(`dart_ping` + `dart_ping_ios`), working in a gitflow-style branching
model: feature branches merge into a long-lived `develop` integration
branch, and `develop` periodically merges into `main` to cut a release.

The existing continuous-integration gate (`§spec:ci`) triggers only on
pull requests targeting `main`. In a gitflow model that is the wrong
checkpoint: by the time code reaches a `develop`→`main` PR it has already
been integrated on `develop`, often across many feature merges. So today a
feature branch can merge into `develop` having never run the suite, and any
breakage it introduces sits on `develop` unnoticed until the release PR
finally runs CI.

That makes failures **late, batched, and hard to attribute**: the release
PR goes red, but the red reflects the combined effect of everything merged
since the last release, not the one change that caused it. The maintainer
then has to bisect after the fact instead of seeing a clean red check on
the individual feature PR that introduced the problem. The integration
branch — the very place a gitflow model expects to always be in a
known-good, releasable state — has no guard keeping it that way.

The fix the maintainer wants is to move the gate earlier: run the same
checks on every PR into `develop`, and protect `develop` so nothing lands
there without passing them — so `develop` stays releasable and breakage is
caught on the PR that caused it.

## CI on develop — success criteria §req:ci-develop-success-criteria

Observable outcomes a tester can verify from the repository's GitHub
surface (Actions tab, PR checks, branch-protection settings):

- **Opening a PR that targets `develop` triggers CI.** The same automated
  suites that run on a PR to `main` start automatically on a PR whose base
  is `develop`, with no manual action. *(must-have)*
- **The checks are at full parity with the `main` gate.** A PR to
  `develop` runs the identical set of jobs a PR to `main` runs today — the
  core `dart_ping` suite on Linux, Windows and macOS; the `dart_ping_ios`
  Dart suite on Linux; the Swift `RunnerTests` suite on macOS; and the
  informational coverage report — with the same deterministic, live-network-
  excluded behavior. *(must-have)*
- **A failing suite shows red on the `develop` PR.** When a change breaks a
  gating suite, the failure is visible as a failed required check on that
  PR, attributable to that change. *(must-have)*
- **`develop` cannot be changed except through a passing PR.** Direct
  pushes to `develop` are rejected, and a PR into `develop` cannot merge
  until its required checks are green — mirroring the protection already on
  `main`. *(must-have)*
- **The `main` gate is unchanged.** PRs to `main` continue to trigger and
  gate exactly as before; adding the `develop` trigger removes or weakens
  nothing on the `main` path. *(must-have)*
- **A manual run is still possible.** The workflow can still be dispatched
  manually from the Actions tab (the existing `workflow_dispatch` path is
  preserved). *(nice-to-have)*

## CI on develop — user stories §req:ci-develop-user-stories

- As the maintainer, I want CI to run automatically when a feature branch
  opens a PR into `develop` so that I see breakage on the PR that caused it
  rather than later on the release PR.
- As the maintainer, I want `develop` protected so that no change can land
  on it without a green run, keeping the integration branch releasable.
- As a contributor, I want my PR into `develop` to show the same checks as a
  PR into `main` so that "green on develop" already means "ready for
  release," with no surprises at the `develop`→`main` step.
- As the maintainer, I want the `develop`→`main` release PR to be
  predictable — green because everything merged into `develop` was already
  green — instead of a batched red I have to bisect.

## CI on develop — quality attributes §req:ci-develop-quality-attributes

- **Determinism (carried over from `§spec:ci`):** the gating checks on
  `develop` stay reproducible — live ICMP round-trips to external hosts are
  excluded, exactly as on the `main` gate. A required check that flaps on a
  network blip trains the maintainer to ignore it.
- **Parity / single source of truth:** the `develop` gate is the *same*
  checks as the `main` gate, not a divergent copy that can drift. "Green on
  develop" and "green on main" mean the same thing.
- **Low maintenance:** extending the trigger should not duplicate job
  definitions; the two branch targets share one workflow so there is one
  place to change a job.
- **Cost is acceptable:** running the full matrix on both `develop` PRs and
  the later `develop`→`main` PR is an accepted cost — confidence on the
  integration branch is worth the extra runner minutes. (Runner cost is not
  a constraint for this work.)

## CI on develop — constraints §req:ci-develop-constraints

- **Full parity, not a lighter subset.** The decision is to run the
  complete `main` job set on `develop` PRs (core OS matrix + iOS Dart + iOS
  Swift + coverage), not a reduced fast gate.
- **`develop` is branch-protected like `main`.** Required green checks
  before merge, no direct pushes. Branch protection is a GitHub repository
  setting outside the workflow file; it is part of this requirement's
  "done" even though it is configured in repo settings rather than in
  `.github/workflows/ci.yml`.
- **The deterministic / live-network exclusion of `§spec:ci` is
  preserved** — the `develop` gate inherits it because it is the same
  workflow, not a separate definition.
- **No change to the `main` trigger or its protection.** This work only
  adds `develop` as an additional gated target.
- **Builds on the existing `§spec:ci` workflow** (`.github/workflows/ci.yml`)
  rather than introducing a new pipeline.

## CI on develop — priorities §req:ci-develop-priorities

- **Must-have:** CI triggers automatically on PRs to `develop`; full
  job parity with the `main` gate; failures visible and attributable on the
  `develop` PR; `develop` branch-protected so merges require green checks;
  the `main` gate unchanged.
- **Nice-to-have:** the manual `workflow_dispatch` path remains available.
- **Out of scope:** any lighter/faster subset gate, coverage-threshold
  enforcement, changes to which tests are live-excluded, and any change to
  the `main` pipeline beyond adding the `develop` target.

---

# Package consolidation — one `dart_ping` with FFI-backed iOS

A packaging and integration-mechanism change driven by two open GitHub
issues that share a single root cause. Resolves
[#28](https://github.com/point-source/dart_ping/issues/28) (collapse the
two packages into one without losing pure-Dart support) and
[#48](https://github.com/point-source/dart_ping/issues/48) (iOS ping
fails inside a secondary isolate).

The root cause both issues share: the iOS path talks Dart↔Swift over
Flutter **platform channels** (`MethodChannel dart_ping_ios` +
`EventChannel dart_ping_ios/events`). Platform channels require the
Flutter plugin machinery — which forces `dart_ping_ios` to be a separate
Flutter package (blocking #28) and routes all messages through the
root-isolate binary messenger (crashing ping in any background isolate,
#48). The maintainer's own diagnosis on #48 was "use `dart:ffi` instead
of platform channels," and the #28 thread waited on Dart's native-code
bundling for non-Flutter packages — now stable (build hooks / code
assets, Dart 3.10 / Flutter 3.38, November 2025).

## Consolidation — problem statement §req:consolidation-problem-statement

The target users are: (1) Flutter iOS app developers who today must add a
**second** package, `dart_ping_ios`, and remember to call
`DartPingIOS.register()` before first use; (2) developers who need to run
ping **inside a background isolate** on iOS and currently cannot; and (3)
the maintainer, who carries two published packages where the platform
split is an artifact of the integration mechanism, not a real domain
boundary.

Today's shape falls short in three ways:

- **Two packages for one capability.** iOS support lives in a separate
  `dart_ping_ios` package solely because Flutter platform channels need a
  plugin. A consumer wanting iOS ping must depend on both packages, keep
  their versions aligned, and wire up registration by hand. The original
  #28 request — fewer projects to maintain, platform dispatch handled
  inside the package — still stands.
- **iOS ping is broken in background isolates.** Because the iOS event
  stream rides a Flutter `EventChannel`, subscribing from a secondary
  isolate throws (`BackgroundIsolateBinaryMessenger ... is invalid` /
  "Background isolates do not support setMessageHandler()"). Developers
  who run network work off the main isolate — a common, recommended
  pattern — cannot use iOS ping at all (#48).
- **The pure-Dart promise is what kept these separate.** The reason the
  packages were never merged is that folding Flutter-plugin code into
  `dart_ping` would force a Flutter SDK on every pure-Dart (CLI, server,
  backend) consumer. That promise — `dart pub add dart_ping` works with no
  Flutter SDK installed — is non-negotiable and must survive any
  consolidation.

The enabling change: Dart's build hooks / code assets are now stable, so
a **pure-Dart** package can compile and bundle native Swift and call it
over `dart:ffi`, with the native build triggered only when the target is
actually iOS. This removes the reason the packages were separate and, by
replacing platform channels with FFI, simultaneously removes the
root-isolate dependency that breaks #48.

This problem area is folded into the **unreleased `dart_ping` 10.0.0**
consolidation train and builds directly on the native-Swift iOS engine
already owned in this repository (the SPM / native-Swift work above). The
Swift ICMP engine stays; only the Dart↔Swift seam changes from platform
channels to FFI, and the package boundary collapses.

## Consolidation — success criteria §req:consolidation-success-criteria

Observable, verifiable outcomes. The first two are the **primary
acceptance pair** — both must pass:

- **One package on iOS.** A Flutter iOS app (SPM enabled, no CocoaPods
  Podfile) adds **only `dart_ping`** — not `dart_ping_ios` — pings a host,
  and receives correct per-probe responses and a run summary. No separate
  iOS package, no `register()` call. *(must-have, primary acceptance)*
- **Pure-Dart unchanged.** A pure-Dart CLI/server project runs
  `dart pub add dart_ping` and pings on Linux / Windows / macOS desktop
  **with no Flutter SDK present**, and no Swift / iOS toolchain is ever
  invoked. *(must-have, primary acceptance — the non-negotiable gate)*
- **Background isolates work on iOS.** Running a ping from a secondary
  isolate on iOS produces responses and a summary without throwing — the
  `BackgroundIsolateBinaryMessenger` failure no longer occurs. This is a
  direct consequence of using FFI rather than platform channels, and is
  asserted explicitly so the chosen FFI design does not reintroduce a
  root-isolate dependency. *(must-have — closes #48)*
- **`dart_ping_ios` is retired.** No new functional release of
  `dart_ping_ios` is required to get iOS support; iOS lives in
  `dart_ping`. The `DartPingIOS.register()` step is gone — iOS auto-wires
  itself. *(must-have)*
- **iOS behavioral parity is preserved.** Responses, summary, error set,
  TTL handling, and round-trip statistics continue to match the other
  platforms exactly as the current native-Swift implementation does — the
  mechanism change does not regress observable behavior. *(must-have)*
- **No manual platform wiring.** A consumer never writes platform-specific
  registration or conditional imports to get iOS support; the package
  dispatches by platform internally. *(high)*
- **Non-iOS consumers pay nothing for iOS.** When the build target is not
  iOS, no Swift is compiled, no build-hook download/compile cost is
  incurred, and no iOS code ships. *(nice-to-have — see priorities; safe
  consolidation outranks this)*

## Consolidation — user stories §req:consolidation-user-stories

- As a Flutter developer targeting iOS, I want to add **one** package
  (`dart_ping`) and have iOS ping just work, so that I don't manage a
  second dependency or remember a registration call.
- As a developer who runs network work off the main thread, I want to ping
  from a **background isolate on iOS** and get results back, so that my app
  stays responsive — the same way ping already works in isolates on the
  other platforms.
- As a pure-Dart developer (CLI, server, backend), I want to keep using
  `dart_ping` with `dart pub add dart_ping` and **no Flutter SDK**, so that
  consolidating the iOS code costs me nothing and breaks nothing.
- As an existing `dart_ping_ios` user upgrading, I want clear migration
  notes — remove the `dart_ping_ios` dependency, delete the
  `DartPingIOS.register()` call — so that moving to the single package is a
  short, well-documented edit.
- As the maintainer, I want one package and one Dart↔native seam (FFI)
  instead of two packages and platform channels, so that I maintain less
  and the platform split reflects real need, not a Flutter-plugin
  artifact.

## Consolidation — quality attributes §req:consolidation-quality-attributes

- **Compatibility (the gate):** `dart_ping` remains a pure-Dart package
  usable with no Flutter SDK. Pure-Dart, non-iOS consumers resolve and run
  exactly as before. iOS support activates only when the build target is
  iOS.
- **Concurrency / isolates:** iOS ping is usable from any isolate, not
  only the root isolate. FFI calls do not depend on the Flutter binary
  messenger.
- **Parity / reliability:** observable iOS behavior (responses, summary,
  errors, TTL, statistics) is unchanged from the current native-Swift
  implementation. The seam change is invisible to consumers of the public
  Dart API.
- **Tooling floor:** requires Dart 3.10 / Flutter 3.38 (Nov 2025) or
  later, where build hooks and code assets are stable. Raising the minimum
  SDK to this floor is acceptable.
- **Testability:** verifiable via the example app on an SPM iOS target
  (single-package import, no `register()`), a pure-Dart CLI on desktop with
  no Flutter SDK, and an iOS background-isolate ping test.
- **Ergonomics:** anything that reduces consumer setup (single import,
  auto-wiring, no manual registration) is favored, provided the
  compatibility gate holds.

## Consolidation — constraints §req:consolidation-constraints

- **Pure-Dart support is non-negotiable.** Any design that would force a
  Flutter SDK on a pure-Dart consumer is rejected. This gate overrides all
  other goals here.
- **Single published package.** iOS native Swift is carried inside
  `dart_ping` and dispatched by platform; `dart_ping_ios` is retired
  outright (no forwarding shim) rather than kept as a thin wrapper.
- **FFI, not platform channels.** The Dart↔Swift seam is `dart:ffi` over a
  bundled code asset, replacing `MethodChannel` / `EventChannel`. This is
  the mechanism that both removes the Flutter-plugin requirement and fixes
  background-isolate use.
- **Reuse the existing Swift engine.** The in-repo native Swift ICMP
  implementation is retained; only its binding to Dart changes.
- **Public Dart API is unchanged.** The `Ping` interface and
  `PingData` / `PingResponse` / `PingSummary` / `PingError` shapes stay the
  same; existing app code keeps working (minus the removed `register()`
  call and `dart_ping_ios` import).
- **Folds into `dart_ping` 10.0.0.** Ships as part of the unreleased
  10.0.0 consolidation train, not a separate later major. `dart_ping_ios`
  is discontinued as part of that release.
- **Raised SDK floor.** Minimum Dart 3.10 / Flutter 3.38, as required by
  stable build hooks / code assets.

## Consolidation — priorities §req:consolidation-priorities

- **Must-have (the gate):** pure-Dart usage survives with no Flutter SDK.
  If `/plan` cannot achieve consolidation without breaking this, **do not
  consolidate** — keep the two packages as they are today. Everything else
  is subordinate to this.
- **Must-have:** single `dart_ping` package carries iOS via FFI; iOS ping
  works in background isolates (#48); `dart_ping_ios` retired and
  `register()` removed (#28); iOS behavioral parity preserved.
- **High:** zero manual platform wiring — single import, auto-wired iOS,
  no conditional imports; clear migration notes for existing
  `dart_ping_ios` users; updated example app importing only `dart_ping`.
- **Nice-to-have:** non-iOS targets pay literally nothing for iOS (no
  Swift compiled, no build-hook cost, no shipped weight). Desired, but
  safe consolidation wins ties over zero-cost.

## Consolidation — open decisions §req:consolidation-open-decisions

Surfaced during discovery and deferred to `/symphonize:plan`, where
mechanism and feasibility are decided:

- **iOS code-asset feasibility (the make-or-break risk).** Whether the
  iOS Swift ICMP engine can be compiled and bundled as a `dart:ffi` code
  asset and linked into an iOS app build **outside** Flutter's plugin
  machinery — covering Xcode integration, code signing, and the iOS
  network sandbox — without compromising the pure-Dart gate. If this
  cannot be done cleanly, the fallback is to keep the two packages. `/plan`
  must answer this before committing to consolidation.
- **FFI threading / isolate model.** The exact FFI design that streams
  per-probe events from the Swift engine to Dart (native threads,
  `NativeCallable`, ports) such that it works from any isolate and does not
  reintroduce a root-isolate dependency.
- **Auto-wiring mechanism.** How iOS initializes without a `register()`
  call — lazy first-use initialization vs. build-hook-driven registration
  — while keeping non-iOS targets untouched.
- **Build-hook activation scope.** How the native build is gated to fire
  only for iOS targets, so pure-Dart and non-iOS builds incur no Swift
  compilation or download cost.
- **Migration surface.** The precise consumer-facing migration (removing
  the `dart_ping_ios` dependency, deleting `register()`, any import
  changes) and how `dart_ping_ios` is marked discontinued on pub.dev.

---

# macOS all-timeout summary (#92)

A focused robustness refinement in `dart_ping`'s macOS exit-code
handling. On macOS, a run where every probe times out but the first
hop returns TTL-exceeded ICMP errors makes the native `ping` exit with
code `2`, which `PingMac` leaves unmapped — so the consumer gets a
generic thrown exception instead of the 100%-loss `PingSummary` that
was already built. The driver is GitHub issue #92.

## macOS all-timeout — problem statement §req:mac-all-timeout-problem-statement

The target users are developers consuming `dart_ping`'s `Ping` stream
on macOS — typically with `await for`, `.drain()`, `.last`, or by
awaiting `stop()` — who expect the run to finish with a terminal
`PingSummary` they can read, even when every probe failed.

On macOS, when a run elicits **no echo replies but does draw ICMP
error packets back** — the classic `ttl=1` / TTL-exceeded case — the
native `ping` binary exits with code **2**. The per-probe timeouts and
TTL-exceeded errors are already captured correctly and a complete
100%-loss `PingSummary` is already built, but exit `2` is not mapped to
a known outcome, so the run instead surfaces a generic
`Exception('Ping process exited with code: 2')`. A consumer awaiting the
terminal summary (`stream.last`) gets that exception instead of the
summary:

```dart
final ping = Ping('201.202.203.204', count: 2, ttl: 1);
final event = await ping.stream.last; // throws instead of yielding a summary
```

This is **environment-dependent**, which is the deeper problem. macOS
BSD `ping` exits `2` when it receives ICMP errors but no echo replies,
and `1` on pure silence. Exit `1` is already mapped to `noReply` (a
clean summary, no throw); exit `2` is not. So the *same* logical
outcome — "we got no reply" — sometimes yields a summary and sometimes
throws, depending only on whether the first hop happened to return a
TTL-exceeded packet. That non-determinism is why the existing
`TTL Exceeded` test is tagged `live` and excluded from CI, where it
would otherwise be flaky.

Current behavior fails these users because an all-timeout macOS run is
a normal, expected diagnostic result — "the host did not answer" — and
they should be able to read that off a summary, not have to catch a
generic exception that double-reports a failure the per-probe error
list already records.

This refines, and does not contradict, the stream-lifecycle robustness
work (`§req:robustness-success-criteria`): that guarantee — an
*unmapped* non-zero exit surfaces a catchable error and closes the
stream — still holds for genuinely unknown codes. This requirement
moves macOS exit `2` out of the "unmapped" bucket and into a known
outcome, so it is no longer governed by that throw-an-error rule.

## macOS all-timeout — success criteria §req:mac-all-timeout-success-criteria

Observable, end-to-end outcomes a tester can demonstrate against the
`Ping` stream on macOS:

- **An all-timeout run yields a summary, not an exception.** A macOS run
  in which every probe fails and the host (or first hop) returns ICMP
  errors but no echo replies terminates with a `PingSummary` event
  reporting 100% packet loss — the consumer's `stream.last` returns that
  summary rather than throwing. *(must-have)*
- **The outcome is deterministic.** The same all-timeout run yields a
  summary regardless of whether the network returned TTL-exceeded ICMP
  errors (exit `2`) or pure silence (exit `1`) — both "no echo reply"
  exit codes resolve to the same observable result. *(must-have)*
- **The summary carries an honest error record.** The terminal summary's
  error list contains the per-probe errors actually observed
  (`requestTimedOut` / `timeToLiveExceeded`) plus a run-level `noReply`,
  matching the shape a pure-silence (exit `1`) run already produces
  today. No synthetic or duplicate error beyond that is introduced.
  *(must-have)*
- **Genuinely unmapped exits still surface an error.** A macOS `ping`
  exit code that is neither a success nor a recognized "no reply" code
  still surfaces a catchable error and closes the stream, preserving
  `§req:robustness-success-criteria`. *(must-have — regression guard)*
- **Normal runs are unchanged.** A successful macOS run (zero exit) and
  a recognized error exit (e.g. unknown host) deliver the same per-probe
  responses, summary, and error list as before. *(must-have — regression
  guard)*
- **The all-timeout path is covered without a live network.** The
  previously `live`-only TTL-exceeded case is exercised by an automated
  test that asserts a summary is produced (not an exception) and runs
  under `dart test` without excluding it via `-x live`. *(high)*

## macOS all-timeout — user stories §req:mac-all-timeout-user-stories

- As a developer running a macOS ping that gets no replies, I want the
  run to finish with a 100%-loss summary I can read so that "the host did
  not answer" is a normal result I handle, not an exception I have to
  catch.
- As a developer setting `ttl=1` (or otherwise drawing TTL-exceeded
  errors) on macOS, I want the same summary I would get from a silent
  timeout so that my code behaves the same regardless of what the
  intermediate hop returns.
- As a developer awaiting `stream.last` / `.drain()` on macOS, I want an
  all-timeout run to return a terminal summary so that my code does not
  throw on a perfectly ordinary "no reply" outcome.
- As an existing `dart_ping` user, I want genuinely unrecognized macOS
  exit codes to keep surfacing a catchable error so that this change does
  not weaken the robustness guarantees I already rely on.

## macOS all-timeout — quality attributes §req:mac-all-timeout-quality-attributes

- **Reliability / determinism:** the observable outcome of an
  all-timeout macOS run does not depend on environment-specific ICMP
  behavior — the same logical result (no reply) produces the same event
  (a 100%-loss summary) every time.
- **Compatibility:** the public API is unchanged — the `Ping` interface
  and the `PingData` / `PingResponse` / `PingSummary` / `PingError`
  shapes stay the same. The summary's error list for this path matches
  the existing exit-`1` (pure-silence) shape, so consumers already
  handling a no-reply run need no changes.
- **Testability:** the all-timeout case is verifiable under `dart test`
  without a live network, removing the `live`-only flakiness that hid
  the bug from CI.

## macOS all-timeout — constraints §req:mac-all-timeout-constraints

- The change is internal to the macOS subprocess path
  (`lib/src/ping/mac_ping.dart`, with lifecycle in
  `lib/src/ping/base_ping.dart`); no change to the public API.
- **macOS only.** Exit `2` is specific to BSD `ping` semantics; Windows
  and Linux use different exit codes and output paths and are explicitly
  out of scope for this requirement.
- This is a **non-breaking, patch-level** change to `dart_ping`.
- Must preserve `§req:robustness-success-criteria`: the "unmapped
  non-zero exit surfaces an error, then closes" guarantee continues to
  hold for codes that are not recognized "no reply" codes.

## macOS all-timeout — priorities §req:mac-all-timeout-priorities

- **Must-have:** macOS exit `2` yields a deterministic 100%-loss summary
  (not a thrown exception) for an all-timeout run, with the no-reply
  outcome reflected in the summary's error list exactly as exit `1`
  already does, and genuinely unmapped exits still surfacing a catchable
  error.
- **High priority:** an automated, non-`live` test covering the
  all-timeout / TTL-exceeded path so the previously environment-dependent
  case is gated in CI.
- **Nice-to-have:** none beyond the above — this is a focused robustness
  refinement.

---

# Host injection safety (#90)

A security fix in how `dart_ping` launches the native `ping` process.
On the Windows-only `forceCodepage: true` path the library runs the
process through `cmd.exe`, and a `host` value carrying shell
metacharacters can break out and run an arbitrary command. The driver
is GitHub issue #90, filed during the 10.0.0 pre-release review.

## Host injection — problem statement §req:host-injection-problem-statement

The target users are developers consuming `dart_ping` whose `host`
value is, or could be, influenced by something outside their own code —
a config file, a saved profile, a UI text field, an API response, a
diagnostics tool that pings whatever address a user types. They expect
that asking the library to ping a string only ever pings (or fails to
ping) that string — never that the string could make their process run
some *other* program.

On one path that expectation breaks. When a caller opts into
`forceCodepage: true` (a Windows-only switch that fixes garbled output
by setting the console codepage to 437 before pinging — see
`§req:windows-roundtrip-problem-statement`), the library starts the
ping process *through the Windows command shell* rather than handing the
arguments straight to the OS. The shell treats certain characters in the
`host` — `&`, `|`, `<`, `>`, `^` — as command separators and redirects.
The escaping the platform applies to each argument does not neutralize
those characters, so a `host` like `8.8.8.8&calc` or `x|whoami` is read
by the shell as "ping this, *then* run that." The injected command runs
with the privileges of the calling process.

The only existing check on `host` confirms that an IP *literal*'s family
matches the requested family (`§req:ipfamily-problem-statement`); a
hostname-shaped string laced with metacharacters sails straight through.
On Windows the `interface` value is already constrained to an IP literal,
so the practical untrusted vector is `host`.

This is not a regression in 10.0.0 — `forceCodepage` predates this
release — but it is a real, high-severity hole worth closing now. Its
reach is constrained: it is **Windows only**, fires **only** when the
caller has turned on `forceCodepage` (off by default), and requires the
caller to be feeding in an untrusted `host`. The default path and all of
Linux/macOS hand arguments directly to the OS with no shell in between,
so they are not exposed. But where it does apply, the cost is the worst
kind — silent, attacker-controlled code execution — and the surface
(a diagnostics library that pings user-supplied targets) is exactly
where untrusted hosts show up. The guarantee a user needs is simple and
absolute: a `host` value is data, never a command.

## Host injection — success criteria §req:host-injection-success-criteria

Observable, verifiable outcomes a tester can demonstrate:

- **A metacharacter host never executes anything.** With
  `forceCodepage: true` on Windows, pinging a `host` such as
  `8.8.8.8&calc`, `x|whoami`, `a>b`, or `a^b` does not launch, spawn, or
  run any program other than the ping itself. No side effect, no injected
  process — on this path or any other. *(must-have)*
- **A dangerous host fails fast and clearly.** When a `host` contains
  characters that cannot be carried safely to the ping process, the
  caller gets a single, catchable error before the ping stream starts —
  a thrown `ArgumentError` that names the problem (an unsafe/invalid host
  value) — rather than a silent run, a hang, or a misleading network
  error. This mirrors the fail-fast rejection already used for
  address-family mismatches (`§req:ipfamily-success-criteria`).
  *(must-have)*
- **The guarantee holds on every path, not just the exploitable one.**
  The "a host is data, never a command" guarantee is stated and upheld
  across all platforms and both the default and `forceCodepage` paths —
  not patched only where it currently bites. A tester can confirm the
  same rejection behavior regardless of platform or flag. *(must-have)*
- **Legitimate hosts are unaffected.** Ordinary hostnames and IPv4/IPv6
  literals — including the `forceCodepage` happy path — ping exactly as
  they do today, with the same responses, summary, and errors. The fix
  is invisible to every valid target. *(must-have — regression guard)*
- **The hole is covered by automated tests.** Injection attempts on the
  `forceCodepage` path, and the rejection of metacharacter hosts, each
  have a test that fails if an injected command could run or if a
  dangerous host is accepted — runnable under `dart test` without a live
  network. *(high)*

## Host injection — user stories §req:host-injection-user-stories

- As a developer building a network-diagnostics tool that pings whatever
  address a user types, I want a host value to only ever be treated as a
  ping target so that a malicious entry can never make my app run another
  program.
- As a developer who turns on `forceCodepage` to fix garbled Windows
  output, I want that switch to carry no security cost so that opting into
  readable output does not open a command-injection hole.
- As a developer passing a host that came from config or an API, when the
  value is unsafe I want a clear, catchable error before anything runs so
  that I can reject it and log it rather than discover an injected command
  after the fact.
- As an existing `dart_ping` user, I want every valid host I ping today to
  keep working unchanged so that this security fix is invisible to my
  working code.

## Host injection — quality attributes §req:host-injection-quality-attributes

- **Security:** an untrusted `host` (and `interface`) value can never be
  interpreted as a command or reach a shell as code. Host input is data.
  This is the defining attribute of this work.
- **Reliability:** a rejected host fails deterministically and fast — a
  thrown error before the stream starts, never a hang or a swallowed
  failure (consistent with `§req:robustness-success-criteria`).
- **Compatibility:** the public API is unchanged in shape — the `Ping`
  interface and `PingData` / `PingResponse` / `PingSummary` / `PingError`
  types stay the same. Every valid host behaves byte-for-byte as before;
  only inputs that were never valid hostnames/IPs are now refused.
- **Testability:** injection and rejection are exercised by automated
  tests that fail if a command could be injected or a dangerous host
  accepted, without needing a live network or a real Windows shell.

## Host injection — constraints §req:host-injection-constraints

- The fix is internal to the core `dart_ping` package (the process-launch
  path in `lib/src/ping/base_ping.dart` and host handling); no change to
  the public API surface.
- Refusing a `host` that carries shell metacharacters is treated as a
  **security patch, not a breaking change** — such strings are not valid
  hostnames or IP literals, and no legitimate caller relies on them.
  Released as a patch-level change to `dart_ping`.
- Scope is host-input safety on the process-launch path. Surfaced by, and
  traceable to, the 10.0.0 pre-release review (issue #90) and related to
  the `forceCodepage` behavior in `§req:windows-roundtrip-constraints` and
  the untrusted-input hardening goal in `§req:robustness-constraints`.

## Host injection — priorities §req:host-injection-priorities

- **Must-have:** a `host` value can never execute a command on any path,
  including Windows `forceCodepage`; unsafe hosts are rejected fast with a
  catchable `ArgumentError` before the stream starts; every valid host
  pings unchanged.
- **High priority:** automated tests covering the `forceCodepage`
  injection vector and the rejection of metacharacter hosts.
- **Nice-to-have:** none beyond the above — this is a focused security
  fix.

## Host injection — open decisions §req:host-injection-open-decisions

Surfaced during discovery and deferred to `/symphonize:plan`, where
mechanism and feasibility are decided:

- **Reject vs. never-shell, or both.** Whether safety comes from
  validating/rejecting unsafe host values before launch, from removing the
  shell from the `forceCodepage` path entirely (so the host never transits
  `cmd.exe` — e.g. setting the codepage as a discrete prior step, or via
  encoding), or from both as defense-in-depth. The required *outcome* (no
  injection, fail-fast on unsafe input) is fixed; the mechanism is open.
- **Exact rejection rule.** The precise definition of an "unsafe" host —
  which characters/shapes are refused and how that rule stays correct
  across platforms without rejecting any legitimate hostname or IP
  literal.
