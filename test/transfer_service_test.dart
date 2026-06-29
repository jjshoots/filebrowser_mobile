import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/transfers/transfer_service.dart';

void main() {
  group('sharedDownloadsSubdir', () {
    test('a path under a Downloads root yields the trailing sub-path', () {
      expect(sharedDownloadsSubdir('/storage/emulated/0/Download/Trips/2024'),
          'Trips/2024');
      expect(sharedDownloadsSubdir('/storage/emulated/0/Downloads/Trips'),
          'Trips');
    });

    test('the Downloads root itself maps to the collection root', () {
      expect(sharedDownloadsSubdir('/storage/emulated/0/Download'), '');
      expect(sharedDownloadsSubdir('/storage/emulated/0/Downloads'), '');
    });

    test('matching is case-insensitive and uses the last Download segment', () {
      expect(sharedDownloadsSubdir('/storage/emulated/0/download/a'), 'a');
      expect(sharedDownloadsSubdir('/Download/old/Download/new'), 'new');
    });

    test('a non-Downloads location nests under the chosen folder name', () {
      expect(sharedDownloadsSubdir('/storage/emulated/0/Documents/Stuff'),
          'Stuff');
    });

    test('an empty path maps to the collection root', () {
      expect(sharedDownloadsSubdir(''), '');
    });
  });
}
