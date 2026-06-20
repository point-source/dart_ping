## Discontinued

This package is **discontinued**. iOS support now ships in
[`dart_ping`](https://pub.dev/packages/dart_ping) (>= 10.0.0) directly, delivered
over `dart:ffi` as a bundled native code asset, so a second package is no longer
required to ping from iOS. Existing consumers migrate by:

- removing the `dart_ping_ios` dependency,
- deleting the `DartPingIOS.register()` call, and
- raising their SDK floor to the `dart_ping` 10.0.0 baseline (Dart 3.10 /
  Flutter 3.38).

No other source change is needed: the public `Ping` API and the `PingEvent`
event model are otherwise unchanged. Prior channel-based releases of
`dart_ping_ios` remain **published and resolvable** for consumers who cannot
adopt the raised SDK floor.

## 6.0.0

- **Breaking change (#63):** the iOS `Ping.stream` now emits the sealed
  `PingEvent` union (`PingResponse` / `PingError` / `PingSummary`) instead of
  the old `PingData`, matching `dart_ping` 10.0.0. A timed-out or TTL-exceeded
  probe is now a single `PingError` carrying its own `seq`/`ip` (no combined
  response+error). Branch on the event type (e.g. `switch` / `is PingSummary`)
  rather than checking which nullable field is populated.
- **Statistics parity (#63):** every event now carries a running
  `RoundTripStats` snapshot (min / avg / max / population stddev / jitter), and
  the terminal `PingSummary` carries the run's final figures plus a derived
  packet-loss percentage. These are computed by **reusing the core `dart_ping`
  `RoundTripStatsAccumulator`** from the per-probe round-trip times — no
  parallel Swift math — so iOS reports the identical statistic set (including
  stddev, which no native tool emits) to the subprocess platforms. A zero-reply
  run reports the round-trip figures as absent (not fabricated zeros) with 100%
  loss.
- **Sub-millisecond precision (#63):** the native engine now surfaces each
  probe's round-trip time at **microsecond** resolution over the channel
  (previously rounded to whole milliseconds), so stddev/jitter stay meaningful
  on fast local links.
- **Breaking change (#69):** track `dart_ping` 10.0.0's `IpVersion` selector.
  `DartPingIOS` now takes an `IpVersion` in place of the `ipv6` boolean, and the
  selected address family is sent to the native engine as `ipVersion` (the enum
  name) over the method channel. Requires `dart_ping` ^10.0.0.
- The literal/address-family mismatch guard now also fires on direct
  `DartPingIOS` construction (an IPv4 literal with `IpVersion.ipv6`, or the
  reverse, throws `ArgumentError`), matching the `Ping(...)` factory.
- Error honesty: the native engine now maps `EAI_NODATA` (a name that resolves
  but has no address of the selected family) to `noRoute` rather than
  `unknownHost`, so the "hostname has no record of this family" case is no
  longer mislabelled. `EAI_NONAME` stays `unknownHost` (Darwin cannot
  distinguish it from a true name miss).
- An IPv6 reply whose hop limit cannot be recovered (no `IPV6_HOPLIMIT`
  control message) now reports a null `ttl` instead of a misleading `0`.
- **NAT64/IPv6-only reachability (#52):** the iOS bridge now forwards the
  default-on `nat64Synthesis` option to the native engine over the method
  channel, so an IPv4 literal can be made to reach an IPv6-only/NAT64 network.
  This batch wires the option through at the bridge level; the live native
  synthesis (the engine acting on the flag) is completed in the follow-on
  batch. Requires `dart_ping` ^10.0.0.
- The minimum Dart SDK floor is raised to **≥3.10** to align with the
  package-consolidation train (#28).

## 5.1.0

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
