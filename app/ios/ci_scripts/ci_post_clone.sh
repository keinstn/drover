#!/bin/sh

# Xcode Cloud post-clone step.
#
# Xcode Cloud clones the repo and then builds the Xcode project, but it knows
# nothing about Flutter. This installs the pinned Flutter SDK (matching
# app/.fvmrc) and generates the iOS build config the archive step needs.
#
# This project resolves its iOS plugins via Swift Package Manager, not
# CocoaPods, so there is no `pod install`: `flutter build --config-only`
# regenerates Generated.xcconfig and the ephemeral generated Swift package,
# and Xcode Cloud resolves the packages during the archive.

set -e

# Read the pinned Flutter version from app/.fvmrc so it stays the single source
# of truth (shared with fvm and the GitHub Actions CI). plutil ships with macOS,
# the only environment this script runs in.
FVMRC="$CI_PRIMARY_REPOSITORY_PATH/app/.fvmrc"
FLUTTER_VERSION="$(plutil -extract flutter raw -o - "$FVMRC")"

echo "Installing Flutter $FLUTTER_VERSION (from app/.fvmrc)"
git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

flutter --version
flutter precache --ios

cd "$CI_PRIMARY_REPOSITORY_PATH/app"
flutter pub get

# Use Xcode Cloud's monotonic build number so every TestFlight upload is
# unique without bumping pubspec's `+N` each release. The marketing version
# (CFBundleShortVersionString) still comes from pubspec. Falls back to 1 for
# local runs where CI_BUILD_NUMBER is unset.
flutter build ios --config-only --release --no-codesign \
  --build-number="${CI_BUILD_NUMBER:-1}"
