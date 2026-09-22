#!/bin/sh

# Inject the two things the build needs that the repository is not allowed to
# carry: the Firebase configuration, and Apple's Sign in with Apple artwork.
# Both are stored as Xcode Cloud secrets.

set -eu
umask 077

: "${GOOGLESERVICE_INFO_PLIST_BASE64:?GOOGLESERVICE_INFO_PLIST_BASE64 is not set}"

plist_path="$CI_PRIMARY_REPOSITORY_PATH/app/ios/Runner/GoogleService-Info.plist"

printf '%s' "$GOOGLESERVICE_INFO_PLIST_BASE64" \
  | base64 --decode > "$plist_path"

plutil -lint "$plist_path"

# Six PNGs travel as one base64'd tar.gz rather than as six secrets: one value
# to rotate, and the 2.0x/3.0x folders Flutter resolves densities by survive
# the trip on their own.

: "${SIGN_IN_WITH_APPLE_ASSETS_BASE64:?SIGN_IN_WITH_APPLE_ASSETS_BASE64 is not set}"

assets_path="$CI_PRIMARY_REPOSITORY_PATH/app/assets"
marks_path="$assets_path/sign_in_with_apple"

mkdir -p "$assets_path"
printf '%s' "$SIGN_IN_WITH_APPLE_ASSETS_BASE64" \
  | base64 --decode \
  | tar -xzf - -C "$assets_path"

# What plutil -lint is doing above, for a PNG: without it a truncated or
# mistyped secret ships a Sign in with Apple button with no logo on it.
marks=$(find "$marks_path" -name '*.png' | wc -l | tr -d ' ')
[ "$marks" -eq 6 ] || {
  echo "expected 6 marks in $marks_path, found $marks" >&2
  exit 1
}
types=$(find "$marks_path" -name '*.png' -exec file --mime-type -b {} + | sort -u)
[ "$types" = "image/png" ] || {
  echo "expected PNGs in $marks_path, found $types" >&2
  exit 1
}
