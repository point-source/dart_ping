// Target-gating decision for the dart_ping build hook
// (§spec:ios-code-asset-build-hook, §spec:pure-dart-preserved).
//
// This is factored out of `build.dart` as a pure function so the gate that
// guarantees "non-iOS builds invoke no native toolchain" is unit-testable
// offline (`dart test`) on the Linux CI host, where the Swift/iOS cross-compile
// itself cannot run (§spec:ci, §spec:ios-tests). The hook calls this before
// touching any toolchain; the test asserts the full matrix.

import 'package:code_assets/code_assets.dart';

/// Whether the build hook should compile the native iOS ICMP engine into a
/// `dart:ffi` code asset.
///
/// Returns `true` ONLY when the consuming toolchain actually requested code
/// assets ([buildCodeAssets]) AND the build target's operating system is iOS.
///
/// Every other case returns `false`, so the hook emits no code asset and invokes
/// no Swift/iOS toolchain — this is the mechanism behind the pure-Dart gate:
///
///  - [buildCodeAssets] is `false` — the analyzer, `dart pub get`, and a
///    pure-Dart `dart test`/`dart run` that links no native code never ask for
///    code assets, so the hook short-circuits without even reading the target
///    OS (and [targetOS] is `null` there because `input.config.code` must not be
///    read when code assets were not requested).
///  - [targetOS] is any non-iOS target — desktop (Linux/macOS/Windows), server,
///    or Android — which is served by the pure-Dart subprocess engine and ships
///    no iOS code.
///
/// See §spec:pure-dart-preserved (non-negotiable gate) and
/// §spec:ios-code-asset-build-hook (iOS-only native build).
bool shouldBuildIosAsset({
  required bool buildCodeAssets,
  required OS? targetOS,
}) => buildCodeAssets && targetOS == .iOS;
