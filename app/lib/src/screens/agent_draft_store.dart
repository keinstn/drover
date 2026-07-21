/// In-memory store for a pane's in-progress composer draft, keyed by paneId.
///
/// The [AgentScreen] is a route that gets popped and re-pushed as the user
/// navigates the herd, disposing its `TextEditingController` each time. Keeping
/// drafts here — outside the route's State — lets a half-typed message survive
/// leaving and returning to the screen. Storage is process-lifetime only; no
/// disk persistence.
class AgentDraftStore {
  final _drafts = <String, String>{};

  /// The default singleton used when no store is injected into [AgentScreen].
  static final AgentDraftStore shared = AgentDraftStore();

  /// The saved draft for [paneId], or null if none is stored.
  String? read(String paneId) => _drafts[paneId];

  /// Saves [text] as the draft for [paneId], or clears it when [text] is empty.
  void write(String paneId, String text) {
    if (text.isEmpty) {
      _drafts.remove(paneId);
    } else {
      _drafts[paneId] = text;
    }
  }

  /// Removes any saved draft for [paneId].
  void clear(String paneId) => _drafts.remove(paneId);
}
