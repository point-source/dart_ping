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
