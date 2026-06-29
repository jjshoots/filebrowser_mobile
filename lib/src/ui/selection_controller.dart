import 'package:flutter/foundation.dart';

/// Holds the browser grid's multi-select state, factored out of
/// `BrowserScreen` so the toggle / select-all / clear logic stays small,
/// self-contained, and unit-testable (see `test/selection_controller_test.dart`).
///
/// Selection is tracked by server *path* — stable across rebuilds and re-sorts —
/// rather than by grid index. The controller is a [ChangeNotifier] so the screen
/// can rebuild its contextual chrome when the set changes.
class SelectionController extends ChangeNotifier {
  final Set<String> _selected = <String>{};
  bool _active = false;

  /// Whether selection mode is engaged (contextual app bar / action bar shown).
  bool get active => _active;

  /// Number of currently selected items.
  int get count => _selected.length;

  /// An unmodifiable snapshot of the selected paths.
  Set<String> get selected => Set.unmodifiable(_selected);

  bool isSelected(String path) => _selected.contains(path);

  /// Enters selection mode (if not already) and selects [path]. This is the
  /// long-press entry point: the gesture both arms the mode and picks the item.
  void enter(String path) {
    _active = true;
    _selected.add(path);
    notifyListeners();
  }

  /// Toggles [path]. Adding the first item arms selection mode; removing the
  /// last item disarms it so the contextual UI never lingers over an empty set.
  void toggle(String path) {
    if (!_selected.remove(path)) {
      _selected.add(path);
      _active = true;
    }
    if (_selected.isEmpty) _active = false;
    notifyListeners();
  }

  /// Adds every path in [paths] (the visible listing) — the 'select all'
  /// action. Never toggles anything off.
  void selectAll(Iterable<String> paths) {
    _selected.addAll(paths);
    if (_selected.isNotEmpty) _active = true;
    notifyListeners();
  }

  /// Empties the set but *stays* in selection mode (the contextual bar's
  /// clear/deselect button).
  void clear() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  /// Exits selection mode entirely: clears the set and disarms the mode (the
  /// back/close button, and the natural state after a batch action completes).
  void exit() {
    if (!_active && _selected.isEmpty) return;
    _selected.clear();
    _active = false;
    notifyListeners();
  }
}
