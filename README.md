# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 17 and newer
and is being implemented in Swift 6 with strict concurrency checking.

The repository is currently at the core-foundation stage. `BleatCore` builds
and its URL, identifier, and Audiobookshelf route behavior is tested. The
SwiftUI application target has not been created yet, so there is not currently
an app executable to launch.

## Requirements

- macOS with Xcode 26.x
- Swift 6.2 or newer
- An installed iOS Simulator runtime for simulator tests

Confirm the active toolchain:

```sh
xcodebuild -version
swift --version
```

If the command-line tools point at a different Xcode installation, select the
required one before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

## Compile

Build the core library in Debug mode:

```sh
swift build
```

Build the optimized Release configuration:

```sh
swift build -c release
```

Build for a generic iOS Simulator destination through Xcode:

```sh
xcodebuild \
  -scheme Bleat \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-derived \
  build
```

Build products and intermediate files are written beneath `.build/`.

## Test

Run the host test suite with code coverage:

```sh
swift test --enable-code-coverage
```

Run the complete current validation gate—host tests, Release build, and iOS
Simulator tests:

```sh
./scripts/test-core.sh
```

The validation script defaults to an `iPhone 17 Pro` simulator. Select another
installed simulator by passing an Xcode destination:

```sh
BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/test-core.sh
```

List available simulator devices when choosing a destination:

```sh
xcrun simctl list devices available
```

To run only host validation, without starting a simulator:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

## Open in Xcode

Open `Package.swift` in Xcode:

```sh
open Package.swift
```

Select the `Bleat` scheme and an iPhone or iPad simulator, then use
**Product → Test**. The current scheme tests `BleatCore`; it does not launch an
application.

## Run against Audiobookshelf

Live-server integration is the next implementation slice. The planned Docker
Compose harness will start seeded Audiobookshelf 2.26.x, the pinned 2.36.0
baseline, and the current stable version for automated contract tests.

Until the application and live-test harness exist, there is no supported
command for connecting this checkout to a personal Audiobookshelf server.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` defines implementation phases and validation gates.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
