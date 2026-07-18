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

# Run the Stage 0 SSH spike, e.g. `just spike --host localhost agents`.
[working-directory('app')]
spike *args:
    fvm dart run tool/spike.dart {{args}}

# --- Plugin (herdr → ntfy push notifications, plugin/) ---

# Run the herdr→ntfy plugin shell tests.
plugin-test:
    sh plugin/test/notify_test.sh

# --- Aggregate ---

check: analyze test plugin-test
