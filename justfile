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
# `asc versions`/`asc builds` need the numeric App Store Connect app ID —
# unlike `asc xcode-cloud run --app`, they don't resolve a bundle ID.
app_id := "6792428012"

# Shared preflight checks for `release`/`tag-release`, wired in as just
# dependencies (see `check:` below for the existing precedent) so they run
# before either recipe's body starts.
[private]
_check-semver-format semver:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{semver}}" ] && ! printf '%s' "{{semver}}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "invalid semver '{{semver}}' (expected e.g. 1.0.1)" >&2
        exit 1
    fi

[private]
_check-on-main:
    #!/usr/bin/env bash
    set -euo pipefail
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" != "main" ]; then
        echo "on '$branch', but this only runs from main" >&2
        exit 1
    fi

# Not a plain dependency: both callers need fresh remote tags fetched first
# (a stale local view would silently miss an already-shipped tag), so this is
# called explicitly from each recipe's body, after that recipe's own fetch.
# No-op when semver is empty, so `release`'s build-only path (no semver, thus
# nothing to have shipped yet) can call this unconditionally too.
[private]
_check-tag-absent semver:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{semver}}" ]; then
        exit 0
    fi
    tag="v{{semver}}"
    if ! git rev-parse "$tag" >/dev/null 2>&1; then
        exit 0
    fi
    if git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
        echo "tag '$tag' already exists — {{semver}} already shipped, use a new semver" >&2
    else
        echo "tag '$tag' exists locally but not on origin — a previous run's push likely failed; push it manually (git push origin $tag) or delete it (git tag -d $tag) and retry" >&2
    fi
    exit 1

# Bump the app version, push, and start an Xcode Cloud build.
#   just release        1.0.0+48 -> 1.0.0+49  (same version, next build)
#   just release 1.0.1  1.0.0+48 -> 1.0.1+49  (new App Store version)
release semver='': (_check-semver-format semver) _check-on-main
    #!/usr/bin/env bash
    set -euo pipefail
    # Every check runs before the first mutation: a failure after the push would
    # leave a version bump behind with no build to go with it.
    git fetch origin --tags --quiet
    just _check-tag-absent "{{semver}}"
    if ! git diff --quiet HEAD -- app/pubspec.yaml; then
        echo "app/pubspec.yaml has uncommitted changes — commit or stash first" >&2
        exit 1
    fi
    if ! command -v asc >/dev/null; then
        echo "asc not found — brew install asc, then asc auth login" >&2
        exit 1
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
    git commit -m "chore(app): bump version to $next" -- app/pubspec.yaml
    git push
    # Builds whatever Xcode Cloud currently sees as main's tip, so a slow SCM
    # sync could pick up the previous commit. Check Git Ref against the bump
    # commit if a build ever archives an unexpected version.
    asc xcode-cloud run --app {{bundle_id}} --workflow {{workflow}} --branch main --output table
    echo "Bumped to $next and started an Xcode Cloud build."

# Record a shipped release in CHANGELOG.md and tag it. Run this only after
# confirming in App Store Connect that the version is actually live — `just
# release <semver>` starts a build, but review/rejection/resubmission can
# take days, during which main keeps moving. Tagging at that point (instead of
# at release time) keeps the tag and changelog range pinned to the commit that
# actually shipped rather than to whatever HEAD happened to be later.
tag-release semver: (_check-semver-format semver) _check-on-main
    #!/usr/bin/env bash
    set -euo pipefail
    # Every check runs before the first mutation, same as `release`.
    for cmd in git-cliff asc jq; do
        if ! command -v "$cmd" >/dev/null; then
            echo "$cmd not found — brew install $cmd" >&2
            exit 1
        fi
    done
    # This recipe runs long after `release` pushed, possibly from a different
    # clone — a stale local main would compute the wrong shipped commit below,
    # and a stale local tag view would miss an already-existing tag (plain
    # `git fetch` only auto-follows tags on newly-fetched objects, not ones
    # added to a commit this clone already has).
    git fetch origin main --tags --quiet
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        echo "local main is out of sync with origin/main — pull first" >&2
        exit 1
    fi
    if ! git diff --quiet HEAD -- CHANGELOG.md; then
        echo "CHANGELOG.md has uncommitted changes — commit or stash first" >&2
        exit 1
    fi
    just _check-tag-absent "{{semver}}"
    tag="v{{semver}}"
    version_id=$(asc versions list --app {{app_id}} --version "{{semver}}" --platform IOS | jq -r '.data[0].id')
    if [ -z "$version_id" ] || [ "$version_id" = "null" ]; then
        echo "no App Store version found for {{semver}} (platform IOS)" >&2
        exit 1
    fi
    # `--include-build` resolves the version's actual attached-build
    # relationship — the build Apple submitted/approved for it — not just the
    # newest upload under that marketing version. They can differ: a
    # build-only `just release` run after submission (still allowed pre-ship)
    # uploads a newer build that was never the one reviewed.
    version_info=$(asc versions view --version-id "$version_id" --include-build)
    # A rejected or still-in-review submission has no place in the changelog.
    # ponytail: only matches READY_FOR_DISTRIBUTION; if this ever needs to run
    # after a later version has superseded it, tag by hand instead of loosening
    # this check.
    state=$(printf '%s' "$version_info" | jq -r '.state')
    if [ "$state" != "READY_FOR_DISTRIBUTION" ]; then
        echo "App Store version {{semver}} is not live yet (state: ${state:-not found}) — check App Store Connect before tagging" >&2
        exit 1
    fi
    # Resolve the commit Apple actually shipped via Xcode Cloud's own build-run
    # records, not by matching pubspec's build number in a commit message:
    # Xcode Cloud assigns CFBundleVersion from its own run counter, which does
    # not always match the number just bumped to in app/pubspec.yaml (confirmed
    # 2026-08-09 — the commit bumping to 1.0.0+49 was not the commit that
    # shipped ASC build 49; run-number 49's sourceCommit had pubspec at +48).
    build_number=$(printf '%s' "$version_info" | jq -r '.buildVersion')
    if [ -z "$build_number" ] || [ "$build_number" = "null" ]; then
        echo "no build attached to App Store version {{semver}} (platform IOS)" >&2
        exit 1
    fi
    workflow_id=$(asc xcode-cloud workflows --app {{bundle_id}} --paginate | jq -r --arg w "{{workflow}}" '.data[] | select(.attributes.name == $w) | .id')
    if [ -z "$workflow_id" ]; then
        echo "no Xcode Cloud workflow named '{{workflow}}' found for {{bundle_id}}" >&2
        exit 1
    fi
    sha=$(asc xcode-cloud build-runs --workflow-id "$workflow_id" --sort "-number" --paginate \
        | jq -r --arg n "$build_number" '.data[] | select((.attributes.number | tostring) == $n) | .attributes.sourceCommit.commitSha')
    if [ -z "$sha" ]; then
        echo "no Xcode Cloud build run found producing build {{semver}}+${build_number}" >&2
        exit 1
    fi
    # The nearest tag reachable from $sha, not just the highest tag overall —
    # a later semver can ship (and get tagged) before an earlier delayed one.
    # v1.0.0 always exists (see CHANGELOG.md bootstrap), so finding none here
    # means something is wrong with the tag history — error instead of
    # silently falling back to "the entire commit history" as the range.
    prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$sha" 2>/dev/null || true)
    if [ -z "$prev" ]; then
        echo "no prior vX.Y.Z tag reachable from ${sha:0:7} — check tag history before tagging" >&2
        exit 1
    fi
    # ponytail: if a later semver is tag-released before an earlier delayed
    # one, `prev` (its nearest ancestor tag) predates the delay, so its range
    # absorbs the delayed version's commits too — and tagging the delayed
    # version afterward repeats them under its own section. Edit CHANGELOG.md
    # by hand to dedupe if this ever happens; upgrade path is tracking already-
    # published commit ranges instead of deriving them from tag ancestry alone.
    git-cliff "$prev..$sha" --tag "$tag" --prepend CHANGELOG.md
    git commit -m "chore(release): add {{semver}} changelog entry" -- CHANGELOG.md
    git tag -a "$tag" "$sha" -m "$tag"
    git push
    git push origin "$tag"
    echo "Tagged $tag at ${sha:0:7} (build ${build_number}) and updated CHANGELOG.md."

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
