import 'package:flutter/material.dart';

/// Text-field context menu that omits iOS "Scan Text" (Live Text).
///
/// Flutter's default `contextMenuBuilder` includes a
/// [ContextMenuButtonType.liveTextInput] ("Scan Text") button. Tapping an empty
/// field surfaces a callout containing only that button, which is unwanted in
/// drover. [noScanTextContextMenuBuilder] rebuilds the toolbar with that item
/// filtered out while preserving every other default action (paste, select
/// all, lookup, share, ...).
List<ContextMenuButtonItem> withoutScanText(
  List<ContextMenuButtonItem> items,
) => items.where((i) => i.type != ContextMenuButtonType.liveTextInput).toList();

/// A `contextMenuBuilder` for `TextField`s that drops the iOS Scan Text button.
Widget noScanTextContextMenuBuilder(
  BuildContext context,
  EditableTextState state,
) {
  final items = withoutScanText(state.contextMenuButtonItems);
  if (items.isEmpty) return const SizedBox.shrink();
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}
