## 10.0.0

### Breaking changes & migration

Each breaking change below carries its migration. Together these are the only
source-level changes a consumer must make; everything under **Added** /
**Changed** / **Fixed** is additive or a bug fix.

**Sealed `PingEvent` stream (#63).** `Ping.stream` is now
`Stream<PingEvent>`. The old `PingData` envelope — a single object whose
`response` / `summary` / `error` fields you null-checked by hand — is replaced
by a `sealed class PingEvent` with three explicit subtypes: `PingResponse` (a
successful probe), `PingError` (a probe/run error, now also carrying optional
`seq` / `ip` so a timed-out or TTL-exceeded probe stays a single
self-identifying event), and `PingSummary` (the terminal run summary, always
the final event before the stream closes). Branch on the type with an
exhaustive `switch` and the compiler enforces that you handle every case.

```dart
// Before (9.x): one PingData with nullable fields, disambiguated by hand
ping.stream.listen((data) {
  if (data.response != null) {/* probe reply */}
  else if (data.error != null) {/* probe/run error */}
  else if (data.summary != null) {/* terminal summary */}
});

// After (10.0.0): a sealed PingEvent — switch on the type
ping.stream.listen((event) {
  switch (event) {
    case PingResponse(): /* probe reply  */
    case PingError():    /* probe/run error */
    case PingSummary():  /* terminal summary — the final event */
  }
});
```

The per-probe `seq` / `ttl` / `time` / `ip` and the summary's `transmitted` /
`received` / `time` / `errors` are all preserved — only the envelope shape
changes. Each variant serializes a `'type'` discriminator, so
`PingEvent.fromMap` / `fromJson` reconstruct the correct subtype.

**`ipv6` boolean → `IpVersion` enum (#69).** The ambiguous `ipv6` boolean on
`Ping` is replaced by an explicit, exclusive `IpVersion` enum. A boolean
`false` was reasonably misread as "prefer IPv4 / dual-stack"; the library has
always selected a single address family exclusively, and `IpVersion` makes
that explicit. It has exactly two values — there is no dual-stack/auto value,
and `IpVersion.ipv4` *excludes* IPv6 rather than preferring it.

- `Ping(host, ipv6: true)` → `Ping(host, ipVersion: IpVersion.ipv6)`
- `Ping(host, ipv6: false)` or omitting it → `Ping(host, ipVersion: IpVersion.ipv4)` (the default)

The ping behavior for an equivalent, matched call is unchanged; only the
selector parameter changes shape. IPv6 is now supported on Windows (served via
`-6`, see #71 under Added); the macOS subprocess path remains IPv4-only and
surfaces an explicit error for an IPv6 selection.

**Round-trip durations serialized in microseconds (#63).**
`PingResponse.toMap`, `PingSummary.toMap`, and `RoundTripStats.toMap` now write
`time` / the stat figures as `inMicroseconds` (decoded as
`Duration(microseconds: …)`), preserving sub-millisecond resolution end-to-end
— the previous `inMilliseconds` truncation rounded stddev/jitter toward zero on
fast links. Serialization round-trips **within** 10.0.0 are consistent, but
JSON/maps persisted by `dart_ping` ≤ 9.x decode 1000× too small under 10.0.0
(a millisecond magnitude read as microseconds), so do not mix serialized
round-trip values across the major boundary.

**`dart_ping_ios` retired; `register()` removed (#28, #48).** iOS support is
now built into `dart_ping` itself, so the separate `dart_ping_ios` package and
its `register()` step are gone. iOS dispatches internally on
`Platform.operatingSystem == 'ios'` and auto-wires when the build target is
iOS — no registration call and no conditional import. For existing
`dart_ping_ios` users:

- Remove the `dart_ping_ios` dependency from your `pubspec.yaml`.
- Delete the `DartPingIOS.register()` call and its
  `import 'package:dart_ping_ios/...';`.
- Raise your SDK floor to the consolidation baseline — Dart 3.10 / Flutter
  3.38 (`sdk: ">=3.10.0 <4.0.0"`).

No other source change is required: the public `Ping` API is otherwise
unchanged, iOS now auto-wires, and ping works from any isolate (closes #48)
because the Dart↔Swift seam moved from Flutter platform channels to
`dart:ffi`. Prior `dart_ping_ios` releases remain published on pub.dev for
consumers who cannot adopt the raised floor.

### Added

- **IPv6 on Windows (#71).** `Ping(host, ipVersion: IpVersion.ipv6)` now works
  on Windows, which previously threw `UnimplementedError`. Windows `ping`
  supports IPv6, so the family is forced with `-6` (as `-4` is for IPv4). The
  Windows reply parser was broadened because IPv6 replies omit `bytes=` and
  `TTL=` (`Reply from ::1: time<1ms`), so an IPv6 probe carries no hop TTL. The
  macOS subprocess path remains IPv4-only and still surfaces an explicit error.
- **Live running statistics (#63).** Every emitted probe event —
  `PingResponse` and `PingError` alike — gains an additive nullable
  `RoundTripStats? stats` carrying a running snapshot of the round-trip
  figures over all successful replies so far in the run. Consumers can drive a
  live latency view and derive packet-loss-so-far without waiting for the
  terminal summary. The snapshot reuses the same accumulator that builds the
  terminal summary, so the last probe's snapshot equals `summary.stats`. The
  field is null on events not produced by the live run path (e.g. a bare
  deserialized event).
- **Summary round-trip statistics & packet loss (#63).** `PingSummary` gains a
  `RoundTripStats? stats` field (min / avg / max / population stddev / jitter /
  sample count) and a derived `packetLoss` getter computed on read from
  `transmitted` / `received` (never stored, so it cannot drift). A zero-reply
  run carries the empty snapshot rather than fabricated zeros.
- **Interface selection (#72).** An optional `interface` on the `Ping` factory
  and the platform constructors accepts either an interface name (e.g. `eth0`)
  or a local source IP address (e.g. `192.168.1.5`), mapped to each platform's
  native flag (Linux/Android `-I`; macOS `-b` for a name / `-S` for an address;
  Windows `-S`, source-address form only). Omitting it leaves the spawned
  command byte-for-byte unchanged.
- **`listNetworkInterfaces()` (#72)**, exported from
  `package:dart_ping/dart_ping.dart`, returns the host's available network
  interfaces so you can present a chooser or validate input and feed a
  name/address straight back into `Ping(host, interface: ...)`. A failure to
  enumerate is reported to the caller, not swallowed.
- **NAT64 / IPv6-only reachability (#52).** A new default-on `nat64Synthesis`
  boolean on the `Ping` factory. On an IPv6-only (NAT64/DNS64) network an IPv4
  literal is otherwise unreachable; synthesis lets the platform reach it. The
  active behavior is delivered on iOS by `dart_ping`'s native engine; on the
  subprocess platforms it is an inert no-op carried for cross-platform parity
  (the spawned command is unchanged and it never raises). Pass
  `nat64Synthesis: false` to restore raw pass-through.

### Changed

- **iOS is built into `dart_ping` over `dart:ffi` (#28).** iOS talks to the
  bundled native Swift ICMP engine through a `dart:ffi` code asset
  (`dart_ping_ffi`) compiled by a build hook **only when the build target is
  iOS**, replacing Flutter's `MethodChannel` / `EventChannel`. The observable
  contract is unchanged: `Ping`, `PingResponse`, `PingError`, and `PingSummary`
  keep the same shapes, event order, and terminal summary. Each iOS `Ping` owns
  its own native run handle and callback — no shared broadcast stream, no
  run-id demux — so concurrent pings to distinct hosts cannot
  cross-contaminate. The full run config (including `ipVersion` and
  `nat64Synthesis`) crosses the FFI seam, so iOS NAT64 synthesis, microsecond
  RTT precision, and the shared stats accumulator are all preserved. iOS ping
  now works from background isolates (the
  `BackgroundIsolateBinaryMessenger ... is invalid` failure, #48, is gone).
- **Minimum Dart SDK raised to ≥3.10 (Flutter 3.38).** Build hooks / code
  assets are stable from that floor; `hooks` and `code_assets` are added as
  **pure-Dart** dependencies and do not pull the `flutter` SDK into
  `dart_ping`'s graph, preserving the pure-Dart gate for CLI/server consumers.
- **Forced address-family resolution (#69).** The selected family is now
  forced, not merely implied by the binary name: Linux/Android pass an explicit
  `-4`/`-6` to the unified `ping`, so `IpVersion.ipv4` can no longer resolve to
  an IPv6 address on a dual-stack host (and vice-versa). macOS IPv6 over the
  subprocess path now surfaces an explicit "unsupported" error. More
  routing/address-family failures map to `ErrorType.noRoute` across platforms,
  while macOS "Host is down" maps to `unknown` rather than being mislabelled.
  The literal/family mismatch guard now also fires on direct platform-class
  construction, not only via the `Ping(...)` factory.
- **Toolchain:** upgraded to `lints` 6 and `test` 1.31, and removed the
  leftover `dart_code_metrics` analysis config (the dev dependency was dropped
  in 9.0.0).
- **Interface round-trip clarification (#85, docs only).** An interface listed
  by `listNetworkInterfaces()` round-trips into `Ping(host, interface: ...)` by
  source address on Windows — a bare interface name is rejected there — while
  the address form round-trips on every platform. No behavior change.

### Fixed

- **Stream lifecycle robustness (#76).** The `Ping` stream could hang forever
  on a process-launch failure (e.g. a missing `ping` binary) or an unmapped
  non-zero exit code. Both now surface a catchable error through the stream's
  error channel and the stream always closes, so consumers (`await for`,
  `.drain()`, `.last`, `stop()`) never deadlock; a missing binary reports that
  the ping binary could not be found. stderr/stdout are decoded and line-split
  independently before merging, so interleaved writes cannot corrupt, split, or
  drop a line. Parser/transform errors route through the error channel instead
  of escaping as uncaught async errors. `stop()` terminates reliably even when
  called during process launch, and consumer pause/resume now actually
  pause/resume the underlying output.
- **TTL-exceeded parser crash on macOS and Windows.** The `seq` capture group
  is now read only when the platform's pattern defines it (previously
  force-unwrapped, throwing "Not a capture group name: seq").
- **`PingSummary.hashCode` consistent with `==`.** Equality already compared
  `errors` element-wise, but `hashCode` used the list's identity hash, so two
  value-equal summaries could produce different hash codes and misbehave as
  `Set`/`Map` keys. `hashCode` now hashes `errors` element-wise.
- **Concurrent-ping isolation (#70)** is now guarded by a network-free
  regression test that overlaps multiple `Ping` instances with interleaved
  per-host output and asserts no field bleeds between runs. The defect did not
  reproduce (each instance already owns only instance-local state), so there is
  no behavior change — the guard prevents future regressions.

## 9.0.1

- Fix #49: No IP response when TTL exceeded on Android platforms
- Add sequence number to PingData on Linux / Android

## 9.0.0

- Implement TTL expiration handling (#49)
- Add "forceCodepage" option for Windows systems with non-English default languages
- Add clearer exception when "ping" binary is not available on the host OS (#50)
- Refactor PingParser and make errorStr param into a List type
- Removed dart_code_metrics dev dependency
- Renamed test files
- Upgraded sdk to Dart 3
- Upgrade dependencies

## 8.0.1

- Fix windows timeout flag (Issue #37)

## 8.0.0

- Use named capture groups for regex parsing
- Return false instead of throwing exception when stop() is called prematurely

## 7.0.2

- Remove windows compatibility warning. Issue #27 / fixed upstream
- Add repository link to pubspec / pub.dev

## 7.0.1

- Add documentation note about apple app sandbox in release mode

## 7.0.0

- Require min dart 2.17 sdk (for enhanced enums)
- Make data classes immutable and add serialization and copyWith methods
- Use lowercase names for enums
- Split tests into multiple files
- Depends on pacakge:collection for list equality comparison
- Update dependencies

## 6.1.2

- Improve documentation
- Improve code formatting

## 6.1.1

- Removed unused ios related files that may have not been tree shaken due to MethodChannel

## 6.1.0

- Add static variable to register iOS plugin with
- When supported, attempt to set system locale before pinging
- Fix pause/resume of stream subscriptions
- Fix docstrings
- Rename files for consistency / clarity

## 6.0.0

- Force timeout and interval to be int instead of double to support ping on all system locales
- Simplify example
- Add additional documentation to readme

## 5.4.2

- Fix ping base to expose encoding override

## 5.4.1

- Allow overriding the character decoder via optional encoding flag

## 5.3.1

- Fix ttl flag on Windows

## 5.3.0

- Implement custom ping parser override to support other languages
- Force IPv4 ping on Windows
- Improve docs

## 5.2.0

- Add command getter to output the string command that will be run on the host OS
- Add command preview to example
- Improve PingData.toString() output

## 5.1.0

- Accumulate errors into PingSummary
- Improve PingData.toString() output
- Don't try to parse non-existent time values on macOS
- Fix macOS summary regex
- Don't throw errors on Windows (just add them to PingSummary stream data)

## 5.0.0

- Implement ttl flag (default 255)
- Identify exit code 1 and update PingSummary when it occurs
- Add errors to stream rather than throwing them
- Fix bug where stream fails to close
- Fix tests on platforms that are not macOS
- Fix multiple race conditions related to early halt / cancel

## 4.0.2

- Fix response parsing on Windows 10

## 4.0.1

- Fix timeout on macOS
- Leave sequence number intact (don't decrement)
- Add tests

## 4.0.0

- Nullsafety
- Consolidate response parser
- Improve error output verbosity

## 3.0.0

- Improve stream management
- stop() is now async
- Throw error if stop() is called before process starts
- Fix macOS UnknownHost error condition output

## 2.0.5

- Fix ping on macOS
- Simplify example

## 2.0.4

- Fix parsing bug when linux ping process times out

## 2.0.3

- Fix issue #2 (broken ping command args on windows)

## 2.0.2

- Remove unused cross-platform code stub so pub.dev correctly reports supported platforms

## 2.0.1

- Improve docs

## 2.0.0

- Drop iOS support to release flutter dependency until an alternative is found

## 2.0.0-dev

- Package resurrected

## 1.0.0

- Initial version, created by Stagehand
