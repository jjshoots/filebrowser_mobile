import 'package:flutter/material.dart';

/// A single breadcrumb: a display [label] and the absolute [path] it links to.
typedef Crumb = ({String label, String path});

/// Splits a `/`-rooted server path into an ordered breadcrumb trail.
///
/// PURE and side-effect free so it can be unit-tested in isolation (see
/// `test/breadcrumbs_test.dart`). The first crumb is always the root, labelled
/// [rootLabel] and pointing at `/`; each subsequent crumb is one deeper path
/// segment with the absolute path that navigates to it.
///
/// Empty segments (leading, trailing, or doubled slashes) are ignored, and
/// segment labels are preserved verbatim — unicode and spaces included.
List<Crumb> breadcrumbsFor(String path, {String rootLabel = 'Files'}) {
  final crumbs = <Crumb>[(label: rootLabel, path: '/')];
  var acc = '';
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    acc = '$acc/$segment';
    crumbs.add((label: segment, path: acc));
  }
  return crumbs;
}

/// Horizontally scrollable breadcrumb trail for the current directory.
///
/// Replaces sole reliance on the back arrow: every ancestor is tappable to jump
/// directly there. Long/deep paths scroll horizontally (anchored to the tail so
/// the current folder stays visible) and never overflow; unicode/space names
/// render verbatim. The back arrow in the AppBar keeps working alongside this.
class Breadcrumbs extends StatelessWidget {
  const Breadcrumbs({
    super.key,
    required this.path,
    required this.onTap,
    this.rootLabel = 'Files',
  });

  /// Current `/`-rooted directory path.
  final String path;

  /// Invoked with the absolute path of the tapped ancestor.
  final ValueChanged<String> onTap;

  final String rootLabel;

  @override
  Widget build(BuildContext context) {
    final crumbs = breadcrumbsFor(path, rootLabel: rootLabel);
    final theme = Theme.of(context);
    final activeColor = theme.appBarTheme.foregroundColor ??
        theme.colorScheme.onSurface;
    final mutedColor = activeColor.withValues(alpha: 0.7);

    final children = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final crumb = crumbs[i];
      final isLast = i == crumbs.length - 1;
      if (i > 0) {
        children.add(Icon(Icons.chevron_right, size: 18, color: mutedColor));
      }
      children.add(
        InkWell(
          onTap: () => onTap(crumb.path),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              crumb.label,
              style: theme.textTheme.titleMedium?.copyWith(
                color: isLast ? activeColor : mutedColor,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    // reverse:true keeps the deepest crumb in view by default while still
    // letting the user scroll back to any ancestor — graceful for deep paths.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
