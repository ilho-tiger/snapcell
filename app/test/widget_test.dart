import 'package:flutter_test/flutter_test.dart';
import 'package:snapcell/main.dart';

void main() {
  testWidgets('app builds and shows its name', (tester) async {
    await tester.pumpWidget(const SnapcellApp());
    expect(find.text('Snapcell'), findsOneWidget);
  });
}
