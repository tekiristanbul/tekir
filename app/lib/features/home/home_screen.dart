import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final apiHealthProvider = FutureProvider<bool>((ref) {
  return ref.watch(apiClientProvider).checkHealth();
});

/// Placeholder home screen: proves the app can reach the local api.
/// Replaced once the real map/discover screens land.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(apiHealthProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('cats of istanbul')),
      body: Center(
        child: health.when(
          data: (ok) => Text(ok ? 'api reachable' : 'api unreachable'),
          loading: () => const CircularProgressIndicator(),
          error: (err, _) => Text('api unreachable: $err'),
        ),
      ),
    );
  }
}
