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
}
