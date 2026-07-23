import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/home/home_screen.dart';
import 'package:app/main.dart';

class _FakeApiClient implements ApiClient {
  @override
  Future<bool> checkHealth() async => true;
}

void main() {
  testWidgets('renders the placeholder home screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(_FakeApiClient())],
        child: const CatsOfIstanbulApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('cats of istanbul'), findsOneWidget);
    expect(find.text('api reachable'), findsOneWidget);
  });
}
