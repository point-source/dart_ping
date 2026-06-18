# Requirements

This document tracks three areas of work:

1. **iOS SPM migration (#73)** — *shipped in `dart_ping_ios` 5.0.0.*
   Replace the `flutter_icmp_ping` dependency with a native Swift ICMP
   engine and ship under Swift Package Manager. Captured in the
   `§req:problem-statement` … `§req:priorities` sections below.
2. **Maintenance & modernization refresh** — a cross-package pass to bring
   dependencies, SDK constraints, documentation, and test coverage current,
   and to surface bugs / security flaws / improvements across the Dart and
   native Swift code. Captured in the `§req:refresh-*` sections.
3. **`base_ping` stream lifecycle robustness (#76)** — fix two edge paths
   in the core `dart_ping` stream where a consumer can hang forever
   instead of seeing an error: an unmapped non-zero exit code, and a
   failed process launch (e.g. a missing `ping` binary). Surfaced by the
   Dart code audit (`§spec:code-audit`). Captured in the
   `§req:robustness-*` sections.
4. **IPv6 / address-family error clarity (#69)** — on IPv6-enabled
   networks (notably mobile data), pinging an IP can fail with a
   misleading "Unknown Host" error when the `ipv6` flag and the target's
   address family disagree, or when the network/adapter cannot route the
   selected family. Treat `ipv6` as an exclusive address-family selector,
   validate obvious literal mismatches up front, and surface honest,
   consistent errors instead of mislabeling them. Captured in the
   `§req:ipfamily-*` sections at the end.

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
