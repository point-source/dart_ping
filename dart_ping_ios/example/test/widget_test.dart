// Basic smoke test for the dart_ping_ios example app.
//
// Builds the app and verifies its initial UI renders, without starting a
// real ping (tapping the button would spawn live network activity).

import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('renders the ping demo UI', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // The app bar title and the initial prompt are shown before any ping runs.
    expect(find.text('DartPing Flutter Demo'), findsOneWidget);
    expect(find.text('Push the button to begin ping'), findsOneWidget);
    // The default host is pre-filled in the input field.
    expect(find.text('google.com'), findsOneWidget);
  });
}
