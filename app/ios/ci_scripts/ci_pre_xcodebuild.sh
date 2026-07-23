#!/bin/sh

# Inject the Firebase configuration that is stored as an Xcode Cloud secret.

set -eu
umask 077

: "${GOOGLESERVICE_INFO_PLIST_BASE64:?GOOGLESERVICE_INFO_PLIST_BASE64 is not set}"

plist_path="$CI_PRIMARY_REPOSITORY_PATH/app/ios/Runner/GoogleService-Info.plist"

printf '%s' "$GOOGLESERVICE_INFO_PLIST_BASE64" \
  | base64 --decode > "$plist_path"

plutil -lint "$plist_path"
