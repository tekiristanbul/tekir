import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/spike/carry_route.dart';

/// Issue #280, concept 3.
///
/// The first two tests are the spike's central finding, written as a test
/// rather than as a claim in a document: the shipped app tags the preview
/// sheet's photo and the cat detail's avatar with the same hero tag, and
/// keeps the sheet alive for 500 ms after pushing the detail so the flight
/// "has a source to leave from" — but no flight has ever started, because
/// `showModalBottomSheet` pushes a `ModalBottomSheetRoute`, which extends
/// `PopupRoute`, and Flutter's [HeroController] refuses any pair that is
/// not two [PageRoute]s.
///
/// Detection is by counting: while a flight is in the air, Flutter hides
/// the child at both ends and draws one shuttle, so the same photo is
/// found once. With no flight, both ends are drawn and it is found twice.
void main() {
  const tag = 'cat-photo-test';

  Widget host({required Widget home}) =>
      MaterialApp(home: Scaffold(body: home));

  Widget source(GlobalKey<NavigatorState> _, VoidCallback onOpen) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Hero(
          tag: tag,
          child: Material(child: Text('foto')),
        ),
        Builder(
          builder: (context) =>
              TextButton(onPressed: onOpen, child: const Text('aç')),
        ),
      ],
    ),
  );

  testWidgets('a hero flies between two page routes', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: source(
            navigator,
            () => navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(
                  body: Hero(
                    tag: tag,
                    child: Material(child: Text('foto')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('aç'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // One copy in the air: this is what a working shared element looks
    // like to this test, and it is the control the next test is read
    // against.
    expect(find.text('foto'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a hero does not fly into a modal bottom sheet, which is what the '
    'shipped map asks it to do',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: source(
              navigator,
              () => showModalBottomSheet<void>(
                context: navigator.currentContext!,
                builder: (_) => const Hero(
                  tag: tag,
                  child: Material(child: Text('foto')),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('aç'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      // Two copies: the map's photo stayed on the map and the sheet drew
      // its own. Nothing travelled, and nothing connected them.
      expect(find.text('foto'), findsNWidgets(2));
      await tester.pumpAndSettle();
    },
  );

  test('the route types are what decide it', () {
    expect(
      ModalBottomSheetRoute<void>(
        builder: (_) => const SizedBox(),
        isScrollControlled: false,
      ),
      isNot(isA<PageRoute<void>>()),
    );
    expect(
      CatPreviewPageRoute<void>(
        cat: const CatMarker(id: 'c', primaryPhoto: '', lat: 0, lng: 0),
        onOpenDetail: () {},
      ),
      isA<PageRoute<void>>(),
    );
  });

  testWidgets('the carry route flies the pin into the preview', (tester) async {
    const cat = CatMarker(
      id: 'c1',
      name: 'tekir',
      // Empty on purpose: the photo widget falls back to its drawn
      // placeholder, so the flight is observable without a network image.
      primaryPhoto: '',
      lat: 41.0256,
      lng: 28.9744,
    );

    await tester.pumpWidget(
      host(
        home: Builder(
          builder: (context) => Stack(
            children: [
              const CarryGhostPin(cat: cat, center: Offset(120, 300)),
              Positioned(
                bottom: 0,
                child: TextButton(
                  onPressed: () => CatPreviewPageRoute.push(
                    context,
                    cat: cat,
                    onOpenDetail: () {},
                  ),
                  child: const Text('aç'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // The pin on the map, before anything is opened.
    expect(find.byIcon(Icons.pets), findsOneWidget);

    await tester.tap(find.text('aç'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // Still exactly one: the pin did not stay behind while a second photo
    // appeared in the sheet — it is the photo, mid-flight.
    expect(find.byIcon(Icons.pets), findsOneWidget);

    await tester.pumpAndSettle();
    // Landed: the sheet's own photo, with the map's pin hidden behind it.
    expect(find.text('tekir'), findsOneWidget);
    expect(find.text('Detaya git'), findsOneWidget);
  });

  testWidgets('reduced motion lands the photo without a flight', (
    tester,
  ) async {
    const cat = CatMarker(
      id: 'c1',
      name: 'tekir',
      primaryPhoto: '',
      lat: 41.0256,
      lng: 28.9744,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  const CarryGhostPin(cat: cat, center: Offset(120, 300)),
                  Positioned(
                    bottom: 0,
                    child: TextButton(
                      onPressed: () => CatPreviewPageRoute.push(
                        context,
                        cat: cat,
                        onOpenDetail: () {},
                      ),
                      child: const Text('aç'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('aç'));
    await tester.pump();

    // No transition to wait out and no flight to watch: the preview is
    // simply there, with its photo, in the same frame. Travel is removed;
    // the destination is not.
    expect(find.text('tekir'), findsOneWidget);
    expect(find.text('Detaya git'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
