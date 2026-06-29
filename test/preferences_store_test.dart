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

  test('download dir is null when never set', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.create();
    expect(store.downloadDir, isNull);
  });

  test('round-trips and survives a reopen for the download dir', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.create();
    await store.setDownloadDir('/storage/emulated/0/Download');
    expect(store.downloadDir, '/storage/emulated/0/Download');

    final reopened = await PreferencesStore.create();
    expect(reopened.downloadDir, '/storage/emulated/0/Download');
  });

  test('clearing (null/empty) the download dir reverts to app storage',
      () async {
    SharedPreferences.setMockInitialValues({'pref_download_dir': '/some/dir'});
    final store = await PreferencesStore.create();
    expect(store.downloadDir, '/some/dir');

    await store.setDownloadDir(null);
    expect(store.downloadDir, isNull);

    await store.setDownloadDir('/x');
    await store.setDownloadDir(''); // empty normalises to "not set"
    expect(store.downloadDir, isNull);
  });
}
