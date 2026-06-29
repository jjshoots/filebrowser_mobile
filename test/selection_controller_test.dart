import 'package:flutter_test/flutter_test.dart';
import 'package:filebrowser_mobile/src/ui/selection_controller.dart';

void main() {
  group('SelectionController', () {
    test('starts inactive and empty', () {
      final s = SelectionController();
      expect(s.active, isFalse);
      expect(s.count, 0);
      expect(s.selected, isEmpty);
    });

    test('enter arms the mode and selects the path', () {
      final s = SelectionController();
      s.enter('/a.txt');
      expect(s.active, isTrue);
      expect(s.isSelected('/a.txt'), isTrue);
      expect(s.count, 1);
    });

    test('toggle adds then removes; disarms when the set empties', () {
      final s = SelectionController();
      s.toggle('/a');
      expect(s.active, isTrue);
      expect(s.isSelected('/a'), isTrue);
      s.toggle('/b');
      expect(s.count, 2);
      s.toggle('/a');
      expect(s.isSelected('/a'), isFalse);
      expect(s.count, 1);
      s.toggle('/b');
      expect(s.count, 0);
      expect(s.active, isFalse); // last removal exits the mode
    });

    test('selectAll adds every path and arms the mode', () {
      final s = SelectionController();
      s.selectAll(['/a', '/b', '/c']);
      expect(s.count, 3);
      expect(s.active, isTrue);
      // Idempotent: re-selecting overlapping paths doesn't duplicate.
      s.selectAll(['/c', '/d']);
      expect(s.count, 4);
    });

    test('clear empties but stays in selection mode', () {
      final s = SelectionController();
      s.selectAll(['/a', '/b']);
      s.clear();
      expect(s.count, 0);
      expect(s.active, isTrue);
    });

    test('exit clears and disarms', () {
      final s = SelectionController();
      s.selectAll(['/a', '/b']);
      s.exit();
      expect(s.count, 0);
      expect(s.active, isFalse);
    });

    test('notifies listeners on real changes only', () {
      final s = SelectionController();
      var notifications = 0;
      s.addListener(() => notifications++);
      s.toggle('/a'); // 1: arm + select
      s.clear(); // 2: empties (still active)
      s.clear(); // no-op, already empty -> no notify
      s.exit(); // 3: disarms (active true -> false)
      s.exit(); // no-op, already inactive+empty -> no notify
      expect(notifications, 3);
    });
  });
}
