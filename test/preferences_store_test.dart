import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:filebrowser_mobile/src/api/models.dart';
import 'package:filebrowser_mobile/src/data/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to name/ascending when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.create();
    expect(store.sortKey, SortKey.name);
    expect(store.sortAscending, isTrue);
    expect(store.sort, (key: SortKey.name, ascending: true));
  });

  test('round-trips a sort preference', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.create();
    await store.setSort(SortKey.size, false);
    expect(store.sortKey, SortKey.size);
    expect(store.sortAscending, isFalse);

    // A fresh store sees the persisted values.
    final reopened = await PreferencesStore.create();
    expect(reopened.sort, (key: SortKey.size, ascending: false));
  });

  test('falls back to defaults on an unknown persisted key', () async {
    SharedPreferences.setMockInitialValues({'pref_sort_key': 'bogus'});
    final store = await PreferencesStore.create();
    expect(store.sortKey, SortKey.name);
  });
}
