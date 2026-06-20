// dart_ping build hook — compiles the in-repo native Swift ICMP engine into a
// single `dart:ffi` code asset, but ONLY when the build target's OS is iOS
// (§spec:ios-code-asset-build-hook). For every other target — pure-Dart
// desktop/server, Android, and the analyzer / `dart pub get` path — it emits no
// code asset and invokes no native toolchain, preserving the non-negotiable
// pure-Dart gate (§spec:pure-dart-preserved).
//
// Layer A (this file): hand-rolled iOS cross-compile. There is no first-party
// Swift code-asset helper, so the hook invokes `swiftc` (via `xcrun`) against the
// iOS SDK directly. Layer B (the flat C ABI in native/include/dart_ping_ffi.h +
// the @_cdecl shim in native/ping_shim.swift) is what `dart:ffi` binds in a later
// batch (#28-2, §spec:ios-ffi-binding).
//
// The Swift/iOS compile is NOT runnable on the Linux CI host (no iOS SDK / no
// `xcrun`); it is hand-verified on macOS per repo convention (§spec:ci,
// §spec:ios-tests). See native/README.md for the standalone verification command.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'gating.dart';

/// The code-asset name. The Dart FFI binding (#28-2) opens this asset as
/// `package:dart_ping/dart_ping_ffi` (i.e. `@Native(assetId: ...)` /
/// `DynamicLibrary` lookup keyed on `package:<packageName>/<assetName>`).
const _assetName = 'dart_ping_ffi';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final buildCodeAssets = input.config.buildCodeAssets;
    // `input.config.code` must only be read when code assets were requested.
    final targetOS = buildCodeAssets ? input.config.code.targetOS : null;

    if (!shouldBuildIosAsset(
      buildCodeAssets: buildCodeAssets,
      targetOS: targetOS,
    )) {
      // Pure-Dart gate: nothing emitted, no Swift/iOS toolchain touched.
      return;
    }

    await _buildIosCodeAsset(input, output);
  });
}

/// Cross-compiles the native engine + shim into one iOS dynamic-library code
/// asset for the requested architecture/SDK and registers it on [output].
Future<void> _buildIosCodeAsset(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final code = input.config.code;
  final iosConfig = code.iOS;
  final minVersion = iosConfig.targetVersion; // minimum iOS deployment version
  final architecture = code.targetArchitecture;

  // Device vs simulator drives both the SDK name and the triple's environment
  // suffix; derive it once so the two cannot drift apart.
  final isSimulator = iosConfig.targetSdk == IOSSdk.iPhoneSimulator;
  // The SDK name `xcrun` understands ("iphoneos" / "iphonesimulator").
  final sdkName = isSimulator ? 'iphonesimulator' : 'iphoneos';

  // Resolve the SDK sysroot. `xcrun` is the iOS-toolchain entry point and is
  // absent on non-macOS hosts — but this branch only runs for an iOS target,
  // which is only ever built by an Xcode-bearing macOS toolchain.
  final sdkPath = (await _run('xcrun', [
    '--sdk',
    sdkName,
    '--show-sdk-path',
  ])).trim();

  final archName = switch (architecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError(
      'dart_ping iOS code asset: unsupported target architecture '
      '"$architecture" (expected arm64 device/simulator or x86_64 simulator).',
    ),
  };

  // A simulator slice uses the `-simulator` environment in the target triple.
  final envSuffix = isSimulator ? '-simulator' : '';
  final targetTriple = '$archName-apple-ios$minVersion$envSuffix';

  final nativeDir = input.packageRoot.resolve('native/');
  final header = nativeDir.resolve('include/dart_ping_ffi.h');
  final sources = <Uri>[
    nativeDir.resolve('PingEngine.swift'),
    nativeDir.resolve('ICMPPacket.swift'),
    nativeDir.resolve('ping_shim.swift'),
  ];

  final outputLibrary = input.outputDirectory.resolve('libdart_ping.dylib');

  // Invoke swiftc through xcrun so the iOS toolchain is selected. The shim imports
  // the flat C ABI header for its shared types via `-import-objc-header`; the
  // dylib's install name is `@rpath/...` so the consuming Xcode/Flutter toolchain
  // can embed and code-sign it as a bundled framework (§spec:ios-code-asset-build-hook).
  await _run('xcrun', [
    '--sdk',
    sdkName,
    'swiftc',
    '-emit-library',
    '-O',
    '-sdk',
    sdkPath,
    '-target',
    targetTriple,
    '-import-objc-header',
    header.toFilePath(),
    for (final source in sources) source.toFilePath(),
    '-o',
    outputLibrary.toFilePath(),
    '-Xlinker',
    '-install_name',
    '-Xlinker',
    '@rpath/libdart_ping.dylib',
  ]);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: outputLibrary,
    ),
  );

  // Re-run the hook when the native sources or the ABI header change.
  output.dependencies.addAll([header, ...sources]);
}

/// Runs [executable] with [arguments], throwing with captured stderr on failure.
Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    final stderr = (result.stderr as String?)?.trim() ?? '';
    throw ProcessException(
      executable,
      arguments,
      stderr.isNotEmpty ? stderr : 'exited with ${result.exitCode}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
