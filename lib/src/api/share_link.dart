import 'models.dart';

/// Builds the human-facing public share-page URL: `<baseUrl>/public/share/<hash>`.
///
/// Quantum serves the share page at `/public/share/<hash>` (this is the exact
/// `shareURL` the create-share response advertises). A bare `/share/<hash>` only
/// 301-redirects there, so the canonical `/public/...` path is used directly —
/// it's the link a user hands to someone else. Tolerates a trailing slash (or
/// several) on [baseUrl]. PURE — see `share_link_test.dart`.
String publicShareUrl(String baseUrl, String hash) {
  var b = baseUrl.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return '$b/public/share/$hash';
}

/// Expiry units offered in the create-share dialog.
///
/// The server only understands `seconds`/`minutes`/`hours`/`days` and silently
/// treats any other unit as `hours`, so [weeks]/[months] are converted to an
/// equivalent day count by [shareExpiryParams] before being sent. [never]
/// produces a non-expiring share.
enum ShareExpiryUnit { hours, days, weeks, months, never }

extension ShareExpiryUnitLabel on ShareExpiryUnit {
  String get label => switch (this) {
        ShareExpiryUnit.hours => 'Hours',
        ShareExpiryUnit.days => 'Days',
        ShareExpiryUnit.weeks => 'Weeks',
        ShareExpiryUnit.months => 'Months',
        ShareExpiryUnit.never => 'Never',
      };
}

/// Maps a dialog selection (an [amount] + [unit]) to the server's
/// `{expires, unit}` create-share parameters.
///
/// Returns `(null, null)` for [ShareExpiryUnit.never] or a non-positive amount —
/// the server then creates a share that never expires. Weeks/months are folded
/// into `days` since the server lacks those units. PURE — see
/// `share_link_test.dart`.
({String? expires, String? unit}) shareExpiryParams(
    int amount, ShareExpiryUnit unit) {
  if (unit == ShareExpiryUnit.never || amount <= 0) {
    return (expires: null, unit: null);
  }
  return switch (unit) {
    ShareExpiryUnit.hours => (expires: '$amount', unit: 'hours'),
    ShareExpiryUnit.days => (expires: '$amount', unit: 'days'),
    ShareExpiryUnit.weeks => (expires: '${amount * 7}', unit: 'days'),
    ShareExpiryUnit.months => (expires: '${amount * 30}', unit: 'days'),
    ShareExpiryUnit.never => (expires: null, unit: null),
  };
}

/// Humanizes a share's expiry for display.
///
/// Returns `'Never expires'` for a non-expiring share, `'Expired'` once the
/// expiry is in the past, otherwise `'Expires in <duration>'` (weeks/days/
/// hours/minutes, coarsest non-zero unit). [now] is injectable for tests. PURE
/// — see `share_link_test.dart`.
String humanizeShareExpiry(FbShare share, {DateTime? now}) {
  if (share.expire == 0) return 'Never expires';
  final current = now ?? DateTime.now();
  final expiresAt = DateTime.fromMillisecondsSinceEpoch(share.expire * 1000);
  if (!expiresAt.isAfter(current)) return 'Expired';
  return 'Expires in ${_humanizeDuration(expiresAt.difference(current))}';
}

String _humanizeDuration(Duration d) {
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  if (d.inDays >= 7) return plural(d.inDays ~/ 7, 'week');
  if (d.inDays >= 1) return plural(d.inDays, 'day');
  if (d.inHours >= 1) return plural(d.inHours, 'hour');
  if (d.inMinutes >= 1) return plural(d.inMinutes, 'minute');
  return 'less than a minute';
}
