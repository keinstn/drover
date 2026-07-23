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
