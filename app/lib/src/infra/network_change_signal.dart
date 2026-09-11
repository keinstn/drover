import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Signals that the OS reports the device's network interface changed (Wi-Fi
/// to Wi-Fi, cellular to Wi-Fi, Wi-Fi back after a drop, ...) — NOT that any
/// particular host is reachable on it. [HostConnectionRegistry.invalidateAll]
/// uses this to drop cached SSH sockets proactively instead of waiting out
/// exec timeouts and poll backoff. This is a signal source only: no retry
/// loop belongs here or on top of it — the existing periodic poll is what
/// actually reconnects, at its own pace.
abstract class NetworkChangeSignal {
  /// Emits once per settled interface change. Broadcast, so the connection
  /// registry and the herd screen can each listen independently.
  Stream<void> get changes;

  Future<void> dispose();
}

/// [NetworkChangeSignal] backed by `connectivity_plus`.
///
/// The FIRST report from the source is treated as the baseline, never as a
/// change, and never emitted (even after the debounce elapses): the
/// underlying plugin (at least on iOS) reports the current state immediately
/// on subscribe, and with nothing yet to compare it against, "here is the
/// current state" cannot be a change. Without this, a cold start would race
/// a real caller: `main.dart` builds this signal and the herd screen opens
/// its first connection at nearly the same time, so the priming report's
/// debounced emission lands mid-connect and `invalidateAll` discards that
/// very first, otherwise-healthy connect — an error flash on every launch.
/// A platform that never primes just costs one skipped invalidation at
/// startup, which is free: the registry is empty or freshly built at that
/// point, so there is nothing stale to invalidate anyway.
class ConnectivityChangeSignal implements NetworkChangeSignal {
  /// [source] defaults to `Connectivity().onConnectivityChanged` (real
  /// platform channel); injectable so tests can drive it with a plain
  /// stream instead. [debounce] defaults to the production trailing-edge
  /// window (see [_onEvent]) but is overridable so a test isn't stuck
  /// waiting it out on the wall clock.
  ConnectivityChangeSignal({
    Stream<List<ConnectivityResult>>? source,
    this._debounce = const Duration(milliseconds: 800),
  }) {
    _subscription = (source ?? Connectivity().onConnectivityChanged).listen(
      _onEvent,
    );
  }

  final Duration _debounce;
  final _controller = StreamController<void>.broadcast();
  late final StreamSubscription<List<ConnectivityResult>> _subscription;
  Timer? _timer;
  bool _sawFirstReport = false;

  @override
  Stream<void> get changes => _controller.stream;

  void _onEvent(List<ConnectivityResult> results) {
    // The first report is the baseline (see the class doc comment), not a
    // change — swallow it and start comparing from the next one.
    if (!_sawFirstReport) {
      _sawFirstReport = true;
      return;
    }

    // "No connectivity" is a reason to stop polling, not a reason to
    // reconnect: connectivity_plus reports interface changes, not
    // reachability, and there is nothing to invalidate onto yet. The
    // following transition back to a real interface is its own event and is
    // not filtered here.
    if (results.every((r) => r == ConnectivityResult.none)) return;

    // iOS fires several onConnectivityChanged events across one Wi-Fi
    // transition (association, DHCP, ...). Debouncing on the TRAILING edge
    // means only the settled state fires; a leading-edge emission would
    // invalidate immediately and then get torn down again by a later event
    // from the SAME transition — repeated teardowns for one transition is
    // exactly what this must not do. 800ms comfortably covers that burst
    // without meaningfully delaying recovery.
    _timer?.cancel();
    _timer = Timer(_debounce, () => _controller.add(null));
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription.cancel();
    await _controller.close();
  }
}
