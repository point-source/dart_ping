# Requirements

This document tracks four areas of work:

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
   `§req:robustness-*` sections at the end.
4. **Interface selection (#72)** — let a developer choose which network
   interface (by interface name or by local source address) pings
   originate from, on the desktop platforms (Linux/Android, macOS,
   Windows), with a nice-to-have helper to enumerate the available
   interfaces. Captured in the `§req:interface-*` sections at the end.
5. **Concurrent-ping isolation (#70)** — a reported defect where two or
   more `Ping` instances run at the same time report the same round-trip
   results instead of each host's own, first seen on Android. Fix so that
   concurrent `Ping` instances are fully independent. Captured in the
   `§req:concurrent-*` sections at the end.

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
