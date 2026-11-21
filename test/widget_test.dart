import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:TiktokGenerateRTMP/main.dart';

void main() {
  testWidgets('app shows login actions when no TikTok cookies exist',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.login), findsOneWidget);
    expect(find.byIcon(Icons.file_upload), findsOneWidget);
  });
}
