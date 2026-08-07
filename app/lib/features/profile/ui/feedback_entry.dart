import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

/// The 0.1 contact/support address (issue #91) — also used in the README
/// and store listing metadata; keep them in sync.
const kFeedbackEmail = 'hello@tekir.istanbul';

const _feedbackSubject = 'Tekir 0.1 geri bildirimi';

/// Release identity shown to users, distinct from pubspec's `version:`
/// (the build/tooling version). Bump alongside each release.
const _appVersion = '0.2';

/// Injectable so tests can capture the constructed [Uri] and simulate a
/// device without a configured mail app; defaults to url_launcher.
final feedbackMailLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => launchUrl,
);

/// Platform is filled only from non-sensitive build metadata (issue #91's
/// privacy rules): the compile-time target, nothing device-identifying.
/// Desktop targets fall outside the 0.1 release matrix and stay blank for
/// the user to fill in.
String feedbackPlatformLabel({TargetPlatform? platform, bool? isWeb}) {
  if (isWeb ?? kIsWeb) return 'Web';
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    _ => '',
  };
}

/// `Uri(queryParameters:)` form-encodes spaces as `+`, which mail clients
/// render literally in the subject/body — hence manual percent-encoding.
String _encodeQuery(Map<String, String> params) => params.entries
    .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
    .join('&');

Uri buildFeedbackMailtoUri({TargetPlatform? platform, bool? isWeb}) {
  final platformLabel = feedbackPlatformLabel(platform: platform, isWeb: isWeb);
  return Uri(
    scheme: 'mailto',
    path: kFeedbackEmail,
    query: _encodeQuery({
      'subject': _feedbackSubject,
      'body':
          'Uygulama sürümü: $_appVersion\n'
          'Platform: $platformLabel\n'
          '\n'
          'Geri bildirimin:\n',
    }),
  );
}

/// The 0.1 feedback entry (issue #91): opens the platform mail composer
/// with a prefilled draft to [kFeedbackEmail]. Shown to both guests and
/// signed-in users near the bottom of the profile screen. Deliberately no
/// in-app form, backend endpoint, or auto-attached diagnostics.
class FeedbackEntry extends ConsumerWidget {
  const FeedbackEntry({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final launch = ref.read(feedbackMailLauncherProvider);
    var opened = false;
    try {
      opened = await launch(buildFeedbackMailtoUri());
    } on Exception {
      opened = false;
    }
    // No configured mail app (or the platform refused the mailto intent):
    // recoverable snackbar with the address itself so the user can still
    // reach us — mirrors follow_button.dart's error pattern.
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'E-posta uygulaması açılamadı. Bize $kFeedbackEmail '
            'adresinden ulaşabilirsin.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _open(context, ref),
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Row(
            children: [
              const Icon(Icons.mail_outline, size: 20, color: AppColors.muted),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Geri bildirim gönder',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.ink,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Hata bildir veya önerini paylaş',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
