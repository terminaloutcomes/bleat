#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
lane="${1:?Pass ios or host}"
: "${GITHUB_OUTPUT:?Run from a GitHub Actions step}"

case "$lane" in
  ios) sdk=iphonesimulator ;;
  host) sdk=macosx ;;
  *) echo "Unknown cache lane: $lane" >&2; exit 64 ;;
esac

# Hash the tools actually selected on this runner, including the SDK contents,
# rather than assuming that the macos-26 runner label selects one Xcode build.
toolchain_hash="$({
  uname -s -m
  sw_vers -productVersion
  xcodebuild -version
  xcrun --find swift
  xcrun swift --version
  xcrun --sdk "$sdk" --show-sdk-version
  shasum -a 256 "$(xcrun --sdk "$sdk" --show-sdk-path)/SDKSettings.plist"
} | shasum -a 256 | cut -d ' ' -f 1)"

if [[ "$lane" == ios ]]; then
  dependency_hash="$(shasum -a 256 Package.swift Package.resolved \
    Bleat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    | shasum -a 256 | cut -d ' ' -f 1)"
  build_hash="$({
    printf '%s\n' "$toolchain_hash" "$dependency_hash" \
      'Bleat Debug iphonesimulator coverage=YES parallel-testing=NO'
    shasum -a 256 project.yml Bleat.xcodeproj/project.pbxproj \
      scripts/test-ci-smoke.sh scripts/ci-cache-keys.sh
  } | shasum -a 256 | cut -d ' ' -f 1)"
  echo "build=ios-build-${build_hash}" >> "$GITHUB_OUTPUT"
else
  dependency_hash="$(shasum -a 256 Package.swift Package.resolved \
    | shasum -a 256 | cut -d ' ' -f 1)"
fi

echo "dependencies=${lane}-dependencies-${toolchain_hash}-${dependency_hash}" >> "$GITHUB_OUTPUT"
