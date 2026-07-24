import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/identity/device_identity.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: CatsOfIstanbulApp()));
}

class CatsOfIstanbulApp extends ConsumerWidget {
  const CatsOfIstanbulApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fire-and-forget: start identity initialization without blocking the UI.
    // Registration failures are silently ignored — public read routes remain
    // accessible. The interceptor attaches the token once init completes.
    ref.read(deviceIdentityProvider.future).ignore();

    return MaterialApp.router(
      title: 'tekir',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }
}
