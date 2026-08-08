# drover dev tasks — run `just` to list recipes.

# List available recipes.
default:
    @just --list

# --- App (Flutter / fvm, run from app/) ---

# Resolve pub dependencies (run once before analyze/test).
[working-directory('app')]
get:
    fvm flutter pub get

# Static analysis.
[working-directory('app')]
analyze:
    fvm flutter analyze --no-pub

# Run the Flutter test suite. Append args, e.g. `just test test/foo_test.dart`.
[working-directory('app')]
test *args:
    fvm flutter test --no-pub {{args}}

# Launch the app on a device/simulator, e.g. `just run -d macos`.
[working-directory('app')]
run *args:
    fvm flutter run {{args}}

# Launch a UI preview with a stubbed herdr backend (no host needed).
# `just preview` lists every screen; `just preview launch` boots one;
# scenarios stay orthogonal, e.g. `just preview agent --dart-define=SCENARIO=blocked`.
[working-directory('app')]
preview name='gallery' *args:
    fvm flutter run -t lib/previews/preview.dart --dart-define=PREVIEW={{name}} {{args}}

# Run the Stage 0 SSH spike, e.g. `just spike --host localhost agents`.
[working-directory('app')]
spike *args:
    fvm dart run tool/spike.dart {{args}}

# --- Release (Xcode Cloud) ---
#
# The workflow is manual-start only; pushing builds nothing. Its previous
# start condition watched app/pubspec.yaml, but that file also changes whenever
# a dependency moves — 13 of 47 such commits carried no version change, and each
# one built a duplicate build number that App Store Connect rejects. Starting
# the build explicitly is the only exact trigger, because Xcode Cloud start
# conditions match paths and cannot read a file's contents.
#
# Needs `asc` (brew install asc), authenticated once with `asc auth login`.
# Credentials live in the system keychain — never in this repo.

bundle_id := "com.keinstn.drover"
workflow := "Default"

# Bump the app version, push, and start an Xcode Cloud build.
#   just release        1.0.0+48 -> 1.0.0+49  (same version, next build)
#   just release 1.0.1  1.0.0+48 -> 1.0.1+49  (new App Store version)
release semver='':
    #!/usr/bin/env bash
    set -euo pipefail
    # Every check runs before the first mutation: a failure after the push would
    # leave a version bump behind with no build to go with it.
    if [ -n "{{semver}}" ] && ! printf '%s' "{{semver}}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "invalid semver '{{semver}}' (expected e.g. 1.0.1)" >&2
        exit 1
    fi
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "main" ]; then
        echo "on '$branch', but the workflow always builds main" >&2
        exit 1
    fi
    if ! git diff --quiet HEAD -- app/pubspec.yaml; then
        echo "app/pubspec.yaml has uncommitted changes — commit or stash first" >&2
        exit 1
    fi
    if ! command -v asc >/dev/null; then
        echo "asc not found — brew install asc, then asc auth login" >&2
        exit 1
    fi
    # Only a semver release touches CHANGELOG.md and tags — a build-only bump
    # (no argument) stays silent, since it isn't a user-facing release.
    if [ -n "{{semver}}" ]; then
        if ! command -v git-cliff >/dev/null; then
            echo "git-cliff not found — brew install git-cliff" >&2
            exit 1
        fi
        if ! git diff --quiet HEAD -- CHANGELOG.md; then
            echo "CHANGELOG.md has uncommitted changes — commit or stash first" >&2
            exit 1
        fi
        tag="v{{semver}}"
        if git rev-parse "$tag" >/dev/null 2>&1; then
            echo "tag '$tag' already exists" >&2
            exit 1
        fi
    fi
    current=$(grep -E '^version: ' app/pubspec.yaml | head -1 | sed 's/^version: //')
    name=${current%+*}
    number=${current##*+}
    if [ "$number" = "$current" ]; then
        echo "version '$current' has no build number (expected e.g. 1.0.0+48)" >&2
        exit 1
    fi
    if [ -n "{{semver}}" ]; then
        name="{{semver}}"
    fi
    next="$name+$((number + 1))"
    sed -i.bak "s/^version: .*/version: $next/" app/pubspec.yaml
    rm -f app/pubspec.yaml.bak
    if [ -n "{{semver}}" ]; then
        # `--unreleased` scopes generation to commits after the last matching
        # tag, so the entry covers only what's new since v$previous.
        git-cliff --tag "$tag" --unreleased --prepend CHANGELOG.md
        # Commit the two paths explicitly; `-a` would sweep up unrelated work.
        git commit -m "chore(app): bump version to $next" -- app/pubspec.yaml CHANGELOG.md
        git tag -a "$tag" -m "$tag"
        git push
        git push origin "$tag"
    else
        git commit -m "chore(app): bump version to $next" -- app/pubspec.yaml
        git push
    fi
    # Builds whatever Xcode Cloud currently sees as main's tip, so a slow SCM
    # sync could pick up the previous commit. Check Git Ref against the bump
    # commit if a build ever archives an unexpected version.
    asc xcode-cloud run --app {{bundle_id}} --workflow {{workflow}} --branch main --output table
    echo "Bumped to $next and started an Xcode Cloud build."

# --- App Store screenshots (iOS simulator) ---
#
# See `.claude/skills/screenshots/SKILL.md` for what to shoot and how to get
# there. Override the device with e.g. `just sim=... sim-prep en`.

sim := "iPhone 16 Pro Max"

# Resolve `sim` to a UDID. A device name is friendlier to type and to read in a
# recipe than a raw UDID, which differs per machine; the first match wins,
# because the same name exists once per installed runtime.
[private]
_sim-udid:
    #!/usr/bin/env bash
    set -euo pipefail
    line=$(xcrun simctl list devices available | grep -F "{{sim}} (" | head -1 || true)
    udid=$(printf '%s' "$line" | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
    if [ -z "$udid" ]; then
        echo "no available simulator named {{sim}}" >&2
        exit 1
    fi
    printf '%s' "$udid"

# Boots the device, sets its language, reboots so it takes effect, then
# RE-APPLIES the status bar override — a reboot clears it, and forgetting that
# put a real clock in an asset twice. The override flags are the ones the
# shipped set was captured with; trimming them makes new shots not match it.
# Idempotent: safe when already booted or already in that locale.
# Prepare the simulator for a screenshot run, e.g. `just sim-prep ja`.
sim-prep locale:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{locale}}" in
        en) region=en_US ;;
        ja) region=ja_JP ;;
        *) echo "unsupported locale '{{locale}}' (expected en or ja)" >&2; exit 1 ;;
    esac
    udid=$(just _sim-udid)
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "{{locale}}"
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$region"
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override \
        --time "9:41" \
        --batteryState charged --batteryLevel 100 \
        --wifiBars 3 --cellularBars 4 --dataNetwork wifi
    echo "{{sim}} ($udid) ready: language {{locale}}, locale $region, status bar 9:41"

# Takes a locale and a name, never an arbitrary path: eight finished captures
# were once staged in a system temp directory that got cleaned, so this recipe
# is unable to write outside the repo. It prints the pixel size for the same
# reason — a capture that isn't 1320 x 2868 has to be visible now, not at
# upload time.
# Capture one store screenshot, e.g. `just sim-shot en 01-hero-prompt`.
sim-shot locale name:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{locale}}" in
        en|ja) ;;
        *) echo "unsupported locale '{{locale}}' (expected en or ja)" >&2; exit 1 ;;
    esac
    if ! printf '%s' "{{name}}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "invalid name '{{name}}' (letters, digits, '.', '_', '-')" >&2
        exit 1
    fi
    udid=$(just _sim-udid)
    out="site/public/screenshots/{{locale}}/{{name}}.png"
    mkdir -p "$(dirname "$out")"
    xcrun simctl io "$udid" screenshot "$out"
    size=$(sips -g pixelWidth -g pixelHeight "$out" \
        | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w, h}')
    echo "$out  $size"

# --- Firebase Functions (Node / TypeScript) ---

# Install Functions dependencies.
[working-directory('functions')]
functions-get:
    npm ci

# Check Functions formatting, linting, and types.
[working-directory('functions')]
functions-check:
    npm run check

# Run Functions unit tests.
[working-directory('functions')]
functions-test:
    npm test

# --- Aggregate ---

check: analyze test functions-check functions-test
