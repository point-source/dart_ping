## Unreleased

- Raise minimum Dart SDK to 3.8.0
- Upgrade to `flutter_lints` 6 and `test` 1.31
- Remove leftover `dart_code_metrics` analysis config

## 5.0.0

- **BREAKING:** The iOS implementation is rewritten as a native Swift ICMP engine owned in this repo; the `flutter_icmp_ping` dependency is **removed**.
- Distribution is now **Swift Package Manager only** — no podspec ships. Buildable under Flutter's SPM build mode.
- Minimum iOS version is now **iOS 13.0**.
- iOS parity gains: honors `ttl`; emits `timeToLiveExceeded`; reports the full error set (`timeToLiveExceeded`, `requestTimedOut`, `unknownHost`, `noReply`, `unknown`); populates `PingSummary.errors`.
- The public Dart API is unchanged — existing app code compiles without edits, and `DartPingIOS.register()` is still the entry point.
- No special entitlements and no extra App Store review steps are required (unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP` socket).
- CocoaPods consumers should stay on the `4.x` (`flutter_icmp_ping`-backed) release, which remains published and resolvable. Because this is a new major version, existing `^4.x` constraints will not auto-pull this SPM-only rewrite.

# 4.0.2

- Fix #56: Upgrade flutter_icmp_ping to 3.1.3

## 4.0.1

- Include IP address in PingResponse

## 4.0.0

- Upgrade dart_ping to 9.0.0
- Upgrade dependencies

## 3.0.0

- Upgrade dart_ping to 8.0.1
- Update example

## 2.0.1

- Improve usage docs
- Add repository link to pubspec
- Fix typos
- Update / improve flutter example

## 2.0.0

- Support dart_ping 7.0.0

## 1.1.0

- Upgrade flutter_icmp_ping to 3.1.0

## 1.0.0

- Initial version
