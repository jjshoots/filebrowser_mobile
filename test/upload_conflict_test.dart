import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/ui/batch_ops.dart';
import 'package:filebrowser_mobile/src/ui/upload_conflict.dart';

void main() {
  group('dedupedUploadName', () {
    test('returns the name unchanged when it is free', () {
      expect(dedupedUploadName({'a.txt'}, 'b.txt'), 'b.txt');
      expect(dedupedUploadName(<String>{}, 'a.txt'), 'a.txt');
    });

    test('inserts " (2)" before the extension on first collision', () {
      expect(dedupedUploadName({'a.txt'}, 'a.txt'), 'a (2).txt');
    });

    test('skips over an already-taken " (2)" variant', () {
      expect(
          dedupedUploadName({'a.txt', 'a (2).txt'}, 'a.txt'), 'a (3).txt');
    });

    test('skips a run of taken variants to the first free index', () {
      expect(
        dedupedUploadName(
            {'a.txt', 'a (2).txt', 'a (3).txt', 'a (4).txt'}, 'a.txt'),
        'a (5).txt',
      );
    });

    test('no-extension names get the suffix at the end', () {
      expect(dedupedUploadName({'README'}, 'README'), 'README (2)');
    });

    test('a leading-dot (hidden) name has no extension', () {
      expect(dedupedUploadName({'.env'}, '.env'), '.env (2)');
    });

    test('multi-dot names only split the final extension', () {
      expect(dedupedUploadName({'archive.tar.gz'}, 'archive.tar.gz'),
          'archive.tar (2).gz');
    });

    test('unicode stems and extensions are preserved', () {
      expect(dedupedUploadName({'föö.jpeg'}, 'föö.jpeg'), 'föö (2).jpeg');
    });
  });

  group('resolveUploadConflict', () {
    test('no collision -> upload under the original name, any policy', () {
      for (final policy in ConflictChoice.values) {
        final plan = resolveUploadConflict(
            existingNames: {'other.txt'}, desiredName: 'a.txt', policy: policy);
        expect(plan.action, UploadAction.upload);
        expect(plan.name, 'a.txt');
      }
    });

    test('collision + overwrite -> overwrite, original name', () {
      final plan = resolveUploadConflict(
          existingNames: {'a.txt'},
          desiredName: 'a.txt',
          policy: ConflictChoice.overwrite);
      expect(plan.action, UploadAction.overwrite);
      expect(plan.name, 'a.txt');
    });

    test('collision + skip -> skip', () {
      final plan = resolveUploadConflict(
          existingNames: {'a.txt'},
          desiredName: 'a.txt',
          policy: ConflictChoice.skip);
      expect(plan.action, UploadAction.skip);
    });

    test('collision + keepBoth -> upload under a deduped name', () {
      final plan = resolveUploadConflict(
          existingNames: {'a.txt', 'a (2).txt'},
          desiredName: 'a.txt',
          policy: ConflictChoice.keepBoth);
      expect(plan.action, UploadAction.upload);
      expect(plan.name, 'a (3).txt');
    });
  });
}
