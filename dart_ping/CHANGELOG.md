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
