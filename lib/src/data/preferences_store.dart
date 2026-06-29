import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

/// SharedPreferences-backed store for lightweight, non-secret UI preferences.
///
/// Secrets (credentials, JWT) live in `SecureStore`; this holds only durable
/// view state. Kept intentionally small — later milestones extend it with
/// view-mode, last-path, etc. by adding a key + typed getter/setter pair.
class PreferencesStore {
  PreferencesStore(this._prefs);

  /// Convenience async constructor that resolves the shared instance.
  static Future<PreferencesStore> create() async =>
      PreferencesStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _kSortKey = 'pref_sort_key';
  static const _kSortAsc = 'pref_sort_asc';
  static const _kDownloadDir = 'pref_download_dir';

  /// Persisted sort column (defaults to [SortKey.name]).
  SortKey get sortKey {
    final raw = _prefs.getString(_kSortKey);
    return SortKey.values.firstWhere(
      (k) => k.name == raw,
      orElse: () => SortKey.name,
    );
  }

  /// Persisted sort direction (defaults to ascending).
  bool get sortAscending => _prefs.getBool(_kSortAsc) ?? true;

  /// Both sort dimensions as a record, with the defaults applied.
  ({SortKey key, bool ascending}) get sort =>
      (key: sortKey, ascending: sortAscending);

  /// Persists the sort preference. Returns once both writes complete.
  Future<void> setSort(SortKey key, bool ascending) async {
    await _prefs.setString(_kSortKey, key.name);
    await _prefs.setBool(_kSortAsc, ascending);
  }

  /// The last download save-location the user picked (an absolute device path
  /// from the SAF directory picker), or null when none has been chosen — in
  /// which case downloads land in the app's private storage. Empty strings are
  /// normalised to null so a cleared value behaves like "never set".
  String? get downloadDir {
    final v = _prefs.getString(_kDownloadDir);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Persists (or, with a null/empty [dir], clears) the default download
  /// save-location offered for subsequent downloads.
  Future<void> setDownloadDir(String? dir) async {
    if (dir == null || dir.isEmpty) {
      await _prefs.remove(_kDownloadDir);
    } else {
      await _prefs.setString(_kDownloadDir, dir);
    }
  }
}
