import 'dart:async';

/// A tiny FIFO async mutex: serializes calls to [run] so at most one
/// section runs at a time, in the order they were submitted. An action that
/// throws still releases the lock for the next queued caller (no poisoning),
/// and its error propagates only to its own caller.
class Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final prev = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }
}
