import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The user-dot blue from the design reference (`--blue`,
/// docs/design/screens/app-states.html) — deliberately outside the
/// terracotta palette so the "you are here" dot never reads as a cat.
const _dotBlue = Color(0xFF5B7F9C);

/// `--tan` from the reference — the muted disc behind state glyphs.
const _tan = Color(0xFFF2E2CD);

bool _reduceMotion(BuildContext context) {
  final media = MediaQuery.of(context);
  return media.disableAnimations || media.accessibleNavigation;
}

/// The "you are here" dot with its sonar pulse (state 13,
/// docs/design/app-states.md). Under reduced motion the pulse never runs;
/// the dot renders as its settled frame. Screen-centered, so it is only
/// honest while the camera still sits on the user's location — state 07
/// dropped it for that reason once panning is possible.
class SonarUserDot extends StatefulWidget {
  const SonarUserDot({super.key});

  @override
  State<SonarUserDot> createState() => _SonarUserDotState();
}

class _SonarUserDotState extends State<SonarUserDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  );

  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = _reduceMotion(context);
    if (_reduce) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 180,
        height: 180,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!_reduce)
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(_controller.value);
                  return Container(
                    width: 44 * (0.4 + 2.4 * t),
                    height: 44 * (0.4 + 2.4 * t),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _dotBlue.withValues(
                        alpha: t < 0.7 ? 0.5 * (1 - t / 0.7) : 0,
                      ),
                    ),
                  );
                },
              ),
            Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _dotBlue,
                border: Border.all(color: const Color(0xFFFDF8F0), width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x592A211A),
                    offset: Offset(0, 3),
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// State 13's status band: the dark pill "yakındaki kediler getiriliyor",
/// visible only after 1.6 s of the initial read (the gate owns that
/// timing). Under reduced motion the spinner holds still.
class MapLoadingStatusPill extends StatelessWidget {
  const MapLoadingStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(AppRadius.full),
        boxShadow: const [
          BoxShadow(
            color: Color(0xCC231911),
            offset: Offset(0, 14),
            blurRadius: 30,
            spreadRadius: -14,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s2 + 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 15,
              height: 15,
              child: _reduceMotion(context)
                  ? const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFFFDF1EC),
                      value: 0.25,
                    )
                  : const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFFFDF1EC),
                    ),
            ),
            const SizedBox(width: AppSpacing.s2 + 2),
            const Text(
              'yakındaki kediler getiriliyor',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: Color(0xFFFDF1EC),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// State 07 · civarda kayıt yok (docs/design/app-states.md): the map
/// works, location is known, and the fetched radius holds no cats — an
/// inviting sand-palette empty state, never the help palette. The radius
/// copy comes from the real search radius of the fetch that returned
/// empty; with no radius known yet the sentence stays number-free rather
/// than inventing one.
class EmptyRadiusCard extends StatelessWidget {
  const EmptyRadiusCard({
    super.key,
    required this.searchRadiusMeters,
    required this.onAddCat,
    required this.onWidenArea,
  });

  final double? searchRadiusMeters;
  final VoidCallback onAddCat;

  /// Null when the camera already sits at the minimum zoom — the button
  /// then renders disabled instead of being a silent no-op.
  final VoidCallback? onWidenArea;

  static String titleFor(double? radiusMeters) {
    if (radiusMeters == null) return 'bu civarda henüz kayıtlı kedi yok';
    return 'bu ${_formatRadiusTr(radiusMeters)}de henüz kayıtlı kedi yok';
  }

  static String _formatRadiusTr(double meters) {
    if (meters < 975) {
      final rounded = ((meters / 50).round() * 50).clamp(50, 950);
      return '$rounded metre';
    }
    final km = meters / 1000;
    final oneDecimal = (km * 10).round() / 10;
    final text = oneDecimal == oneDecimal.roundToDouble()
        ? '${oneDecimal.round()}'
        : oneDecimal.toStringAsFixed(1).replaceFirst('.', ',');
    return '$text kilometre';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.xl - 4),
      elevation: 6,
      shadowColor: const Color(0x8C2A1F1B),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: kTapMin,
                  height: kTapMin,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _tan,
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppRadius.md),
                      ),
                    ),
                    child: Icon(Icons.pets, size: 20, color: AppColors.faint),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3 + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titleFor(searchRadiusMeters),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontSize: 19, height: 1.3),
                      ),
                      const SizedBox(height: AppSpacing.s1 + 2),
                      const Text(
                        'gördüğün ilk kediyi eklersen mahalledeki herkes '
                        'onu takip edebilir.',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: AppColors.faint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3 + 2),
            Row(
              children: [
                Expanded(
                  child: _CardButton(
                    label: 'ilk kediyi ekle',
                    icon: Icons.add,
                    background: AppColors.primary,
                    foreground: AppColors.primaryInk,
                    onTap: onAddCat,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2 + 1),
                _CardButton(
                  label: 'alanı genişlet',
                  background: AppColors.surfaceAlt,
                  foreground: AppColors.muted,
                  onTap: onWidenArea,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final ink = enabled ? foreground : foreground.withValues(alpha: 0.45);
    return Material(
      color: enabled ? background : background.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(AppRadius.md + 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md + 2),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: ink),
                const SizedBox(width: AppSpacing.s2),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The map read's error state — contract copy, no blame, one action
/// (docs/design/app-states.md, global rules). Shown when a viewport fetch
/// fails, and by the gate's 6 s fallback when the initial read overruns.
class MapErrorBanner extends StatelessWidget {
  const MapErrorBanner({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s2,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: AppColors.muted,
              size: 18,
            ),
            const SizedBox(width: AppSpacing.s2),
            const Expanded(
              child: Text(
                'yakındaki kediler yüklenemedi',
                style: TextStyle(color: AppColors.ink),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(kTapMin, kTapMin),
                foregroundColor: AppColors.primary,
              ),
              child: const Text('tekrar dene'),
            ),
          ],
        ),
      ),
    );
  }
}
