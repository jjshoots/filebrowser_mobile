import 'package:path/path.dart' as p;

import 'batch_ops.dart';

/// What an upload should do once its destination name has been checked against
/// the names already present in the target directory. The companion to
/// move/copy's [ConflictChoice] (which models the *user's* decision); this is
/// the concrete *action* the upload pipeline then carries out.
enum UploadAction {
  /// No collision (or a "keep both" rename): send the file under [UploadPlan.name]
  /// with `override=false` so the server never clobbers an unrelated file.
  upload,

  /// The user chose to replace the existing file: send under the original name
  /// with `override=true`.
  overwrite,

  /// The user chose to leave the existing file untouched: don't upload at all.
  skip,
}

/// The resolved outcome for a single upload: the [action] to take and the final
/// [name] to upload as (unchanged except for "keep both", which yields a
/// non-colliding `name (n).ext` variant).
typedef UploadPlan = ({UploadAction action, String name});

/// Returns the first non-colliding variant of [desiredName] against
/// [existingNames], inserting ` (n)` (n starting at 2, macOS/Finder style)
/// before the extension. Pure — collisions are resolved purely from the given
/// set, so it is unit-testable without a server probe.
///
/// Mirrors the File Browser web "keep both" suffixing but with a space, as the
/// product spec requires (e.g. `report.pdf` -> `report (2).pdf`). Extension is
/// split with POSIX rules, so a leading-dot name has no extension
/// (`.env` -> `.env (2)`) and a no-extension name keeps the suffix at the end
/// (`README` -> `README (2)`). [desiredName] is a bare basename (no slashes).
///
/// ```
/// dedupedUploadName({'a.txt'}, 'a.txt')              == 'a (2).txt'
/// dedupedUploadName({'a.txt', 'a (2).txt'}, 'a.txt') == 'a (3).txt'
/// dedupedUploadName({'a.txt'}, 'b.txt')              == 'b.txt'   // free
/// ```
String dedupedUploadName(Set<String> existingNames, String desiredName) {
  if (!existingNames.contains(desiredName)) return desiredName;
  final ext = p.posix.extension(desiredName); // '' or leading-dot, e.g. '.txt'
  final stem = desiredName.substring(0, desiredName.length - ext.length);
  var n = 2;
  while (true) {
    final candidate = '$stem ($n)$ext';
    if (!existingNames.contains(candidate)) return candidate;
    n++;
  }
}

/// Maps a user's [policy] to a concrete [UploadPlan] for uploading [desiredName]
/// into a directory that already contains [existingNames]. PURE and testable:
/// the entire decision (action + final name) is a function of its inputs.
///
///  * No collision -> [UploadAction.upload] under [desiredName], regardless of
///    [policy] (so a non-conflicting member of a "apply to all overwrite" batch
///    still uploads cleanly with `override=false`).
///  * [ConflictChoice.overwrite] -> [UploadAction.overwrite] under [desiredName].
///  * [ConflictChoice.skip]      -> [UploadAction.skip].
///  * [ConflictChoice.keepBoth]  -> [UploadAction.upload] under
///    [dedupedUploadName].
UploadPlan resolveUploadConflict({
  required Set<String> existingNames,
  required String desiredName,
  required ConflictChoice policy,
}) {
  if (!existingNames.contains(desiredName)) {
    return (action: UploadAction.upload, name: desiredName);
  }
  switch (policy) {
    case ConflictChoice.overwrite:
      return (action: UploadAction.overwrite, name: desiredName);
    case ConflictChoice.skip:
      return (action: UploadAction.skip, name: desiredName);
    case ConflictChoice.keepBoth:
      return (
        action: UploadAction.upload,
        name: dedupedUploadName(existingNames, desiredName),
      );
  }
}
