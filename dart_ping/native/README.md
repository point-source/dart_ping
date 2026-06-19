# `dart_ping/native/` — iOS ICMP engine + flat-C FFI shim

This directory carries the native iOS ICMP ping engine and the thin C ABI that
the Dart layer reaches it through. It exists for the package consolidation in
issue #28 (§spec:ios-code-asset-build-hook, §spec:ios-ffi-binding,
§spec:swift-icmp-engine).

## Files

- `PingEngine.swift` — the audited, Flutter-agnostic ICMP echo engine
  (§spec:swift-icmp-engine). **Transient duplicate** of the
  `dart_ping_ios` source; de-duplicated when `dart_ping_ios` is retired (#28).
- `ICMPPacket.swift` — ICMP/ICMPv6 framing, checksum, reply parsing. Same
  transient-duplicate status.
- `include/dart_ping_ffi.h` — the **stable flat C ABI** (`dart_ping_start` /
  `dart_ping_stop` / one event callback). This is the compile contract the
  build hook passes to `swiftc` (`-import-objc-header`) and that the Dart FFI
  binding (#28-2) consumes.
- `ping_shim.swift` — the hand-written `@_cdecl` shim that marshals the engine's
  Swift `Event`s into the flat `dart_ping_event` struct and converts the C start
  arguments into a `PingEngine.Config`.

## How this is built (and when it is NOT)

This native tree is compiled into a **single iOS `dart:ffi` code asset** by
`dart_ping/hook/build.dart` (Workstream 3, not in this batch) **only when the
build target's operating system is iOS**. For every other target — pure-Dart
desktop, server, Android, and the analyzer / `dart pub get` path — the hook
emits no code asset and invokes no native toolchain
(§spec:pure-dart-preserved, §spec:ios-code-asset-build-hook).

**This source is NOT Linux-compilable.** The engine imports Darwin networking
APIs (`socket`/`recvmsg`/`getaddrinfo`/ICMPv6 socket options); it has no Linux
equivalent and is never compiled on Linux CI. Per repo convention
(§spec:ios-tests, §spec:ci) the iOS Swift compile is **hand-verified on macOS**,
not gated on Linux CI.

## macOS hand-verification

On a macOS host with Xcode and the iOS SDK installed, a reviewer compiles the
three Swift files against the iOS SDK with the C header imported, then confirms
the two exported C symbols are present. The minimum iOS version is **13.0**,
matching the existing `dart_ping_ios` `Package.swift`. Run from this `native/`
directory's parent (`dart_ping/`):

```sh
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
swiftc -emit-library \
  -sdk "$SDK" -target arm64-apple-ios13.0 \
  -import-objc-header native/include/dart_ping_ffi.h \
  native/PingEngine.swift native/ICMPPacket.swift native/ping_shim.swift \
  -o libdart_ping.dylib

# Expect the two exported C entry points (leading underscore is the Mach-O ABI):
nm -gU libdart_ping.dylib | grep dart_ping_
#   _dart_ping_start
#   _dart_ping_stop
```

The exact flags WS3's hook invokes may differ (e.g. emitting a static archive /
`.a` for code-signed framework embedding, additional architectures, bitcode
settings); the point of this command is the hand-verification a macOS reviewer
runs to confirm the engine + shim cross-compile for iOS and export the flat C
ABI. WS3 owns the production invocation.
