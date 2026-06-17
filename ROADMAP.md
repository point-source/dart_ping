# Roadmap

Work remaining to close the **Maintenance & modernization refresh**
(`§spec:dependency-currency` … `§spec:code-audit`). The #73 SPM sections
are implemented and are not tracked here.

Sections are in build-dependency order: the toolchain modernization
establishes the green-analyze baseline every later section builds on; the
audit runs last so it reviews the post-refresh state.

## Toolchain modernization

Bring both packages onto current dependencies, SDK floor, and lint rules
so a consumer gets up-to-date resolution and a clean analyze.

### §road:modernize-core-toolchain
Bump `dart_ping/pubspec.yaml` to `sdk: ">=3.8.0 <4.0.0"`, `lints: ^6.0.0`,
`test: ^1.31.0`, remove the `dart_code_metrics` block from
`dart_ping/analysis_options.yaml`, and fix every resulting finding until
`dart analyze` is clean (§spec:dependency-currency, §spec:sdk-floor,
§spec:lint-baseline).

### §road:modernize-ios-toolchain
Bump `dart_ping_ios/pubspec.yaml` to `sdk: ">=3.8.0 <4.0.0"`,
`flutter_lints: ^6.0.0`, `test: ^1.31.0`, remove the `dart_code_metrics`
block from `dart_ping_ios/analysis_options.yaml`, and fix every resulting
finding until `flutter analyze` is clean (§spec:dependency-currency,
§spec:sdk-floor, §spec:lint-baseline). Depends on §road:modernize-core-toolchain
(re-resolves against the updated `dart_ping`).

**Verify:** In `dart_ping`, run `dart pub get` then `dart analyze` — both
succeed with zero issues, and `dart pub outdated` shows no direct dependency
behind its latest resolvable. Repeat in `dart_ping_ios` with
`flutter pub get` / `flutter analyze`. Confirm neither
`analysis_options.yaml` still contains a `dart_code_metrics` block.

## Parser correctness & test suite

Fix the cross-platform TTL-exceeded crash and bring the suite to fully
green with coverage over the previously thin seams.

### §road:fix-ttl-seq-guard
Guard the `seq` named-group read in the TTL-exceeded branch of
`dart_ping/lib/src/models/ping_parser.dart` (read it only when the active
pattern defines the group, as the timeout/response branches already do) so
macOS and Windows TTL-exceeded lines emit a `timeToLiveExceeded` `PingData`
instead of throwing (§spec:ttl-exceeded-parse). Depends on
§road:modernize-core-toolchain.

### §road:fill-coverage-gaps
Add tests for the parser error/edge paths (`errorStrs` matches, malformed
summary, the `seq`/no-`seq` TTL split) and the `base_ping` stream
start/stop lifecycle under `dart_ping/test/` (§spec:test-coverage). Depends
on §road:fix-ttl-seq-guard.

**Verify:** Run `dart test` in `dart_ping` and `flutter test` in
`dart_ping_ios` — both pass with no failing or skipped tests, including the
macOS and Windows "TTL Exceeded" cases in `parse_test.dart`.

## Documentation accuracy

Bring the repository's docs in line with what actually ships (native-Swift
SPM iOS at 5.0.0, current SDK floor, supported platforms).

### §road:refresh-docs
Update the root `README.md` to describe `dart_ping_ios` as a native Swift
ICMP plugin distributed via Swift Package Manager (removing the false
"adds cocoa dependencies"/CocoaPods claim), and align each package
`README.md`, `CHANGELOG.md`, and public dartdoc with the current platforms,
SDK floor, and iOS distribution model (§spec:doc-accuracy). Depends on
§road:modernize-core-toolchain (SDK floor value).

**Verify:** Read the root `README.md` and both package `README.md`s — none
mention CocoaPods/cocoa dependencies for current iOS support; the stated
SDK floor matches the pubspecs (`>=3.8.0`); the documented install/usage
steps work against the current packages.

## Code audit & Swift hardening

One-time review of both packages' Dart and the native Swift engine,
producing a triaged finding list with cheap, clearly-correct fixes applied.
Runs last so it audits the post-refresh state.

### §road:audit-dart
Review the Dart source of both packages for bugs, security flaws, and
improvements; record an enumerated, triaged finding list and apply the
cheap, clearly-correct fixes (§spec:code-audit). Depends on the Parser
correctness & test suite section.

### §road:audit-swift-hardening
Review the native Swift engine (`PingEngine.swift`, `ICMPPacket.swift`,
`DartPingIosPlugin.swift`), explicitly assessing the untrusted-inbound-ICMP
parsing paths (IPv4-header strip, Echo Reply parse, Time Exceeded sequence
recovery, hand-rolled `cmsg` walk) for out-of-bounds reads and
malformed-input handling; record triaged findings and apply cheap,
clearly-correct fixes (§spec:code-audit).

**Verify:** A triaged finding list exists covering both packages' Dart and
the three Swift sources, with security-relevant Swift parsing paths
explicitly assessed and no unaddressed high-severity finding remaining;
`dart test` / `flutter test` stay green after any applied fixes.
