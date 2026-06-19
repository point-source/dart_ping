// Offline guard for the build hook's target gate (§spec:pure-dart-preserved,
// §spec:ios-code-asset-build-hook).
//
// The hook's actual Swift/iOS cross-compile cannot run on the Linux CI host
// (no iOS SDK / no `xcrun`), so it is hand-verified on macOS (§spec:ci,
// §spec:ios-tests). What CAN be verified offline — and is the load-bearing
// pure-Dart guarantee — is the gate decision: a non-iOS build, and any build
// that did not request code assets, must NEVER reach the native toolchain. This
// test pins that decision so a regression that would compile Swift (or download
// a toolchain) on a pure-Dart, non-iOS consumer fails here.

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/gating.dart';

void main() {
  group('shouldBuildIosAsset', () {
    test('builds only for an iOS target that requested code assets', () {
      expect(
        shouldBuildIosAsset(buildCodeAssets: true, targetOS: OS.iOS),
        isTrue,
      );
    });

    test('never builds for a non-iOS target (the pure-Dart platforms)', () {
      for (final os in [
        OS.linux,
        OS.macOS,
        OS.windows,
        OS.android,
        OS.fuchsia,
      ]) {
        expect(
          shouldBuildIosAsset(buildCodeAssets: true, targetOS: os),
          isFalse,
          reason: 'no iOS code asset (and no Swift toolchain) for $os',
        );
      }
    });

    test('never builds when code assets were not requested', () {
      // The analyzer / `dart pub get` / pure-Dart `dart test` path: no code
      // assets requested, so the hook short-circuits without reading the target
      // OS (hence null here).
      expect(
        shouldBuildIosAsset(buildCodeAssets: false, targetOS: null),
        isFalse,
      );
      // Defensive: buildCodeAssets:false dominates even if an OS leaks through.
      expect(
        shouldBuildIosAsset(buildCodeAssets: false, targetOS: OS.iOS),
        isFalse,
      );
    });

    test('covers every known OS (no unhandled target silently builds)', () {
      for (final os in OS.values) {
        final builds = shouldBuildIosAsset(
          buildCodeAssets: true,
          targetOS: os,
        );
        expect(builds, os == OS.iOS, reason: 'only iOS builds; $os must not');
      }
    });
  });
}
