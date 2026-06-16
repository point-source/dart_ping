# Requirements

Tracks issue #73 — "Support Swift Package Manager".

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
