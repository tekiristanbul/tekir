import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../analytics/analytics.dart';
import '../../features/auth/ui/auth_gate.dart';
import '../theme/app_theme.dart';

const _fabDiameter = 46.0;

/// Persistent chrome for the 3 root tabs (Harita/Keşfet/Profil) plus a
/// center-docked add-cat fab, ported from the approved prototype's
/// `bottomNav`/`.bottom-nav`/`.nav-fab` exactly (prototype/app.js:153-167,
/// prototype/styles.css:511-542) — issue #80 product-owner review, finding
/// 1: the corner profile button this app had before didn't match this IA at
/// all. [StatefulShellRoute.indexedStack] (app_router.dart) is what makes
/// this chrome disappear the moment any other route (cat detail, add-cat,
/// login, badges, ...) is pushed on top, matching the prototype's own
/// per-screen nav visibility (never present on detail/badges/settings/
/// add-cat/login).
///
/// The fab is Scaffold's own `floatingActionButton` slot (centerFloat,
/// floating just above the bottom nav bar) rather than a manually
/// positioned overlap — this is the same mechanism the map's old add-cat
/// fab already relied on, which is what let it sit correctly above
/// MapScreen's real GoogleMap platform view with no extra plumbing: a
/// hand-positioned overlap here would need `PointerInterceptor` (mirroring
/// `_ProfileButton`/`_NotificationsButton`'s own workaround for exactly
/// that platform view), since Scaffold's dedicated fab slot already
/// composites correctly above `body` on its own.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: _BottomNav(
        currentIndex: navigationShell.currentIndex,
        onTabSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
      ),
      // Map tab only (product owner, issue #91 review): on Keşfet/Profil
      // the centerFloat fab overlapped real content (e.g. the profile
      // screen's bottom entries) with no map underneath to justify it.
      floatingActionButton: navigationShell.currentIndex == 0
          ? const _AddCatFab()
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.currentIndex, required this.onTabSelected});

  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s2,
        6,
        AppSpacing.s2,
        bottomInset + 4,
      ),
      child: Row(
        children: [
          Expanded(
            child: _NavItem(
              icon: Icons.map_outlined,
              label: 'Harita',
              isActive: currentIndex == 0,
              onTap: () => onTabSelected(0),
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.explore_outlined,
              label: 'Keşfet',
              isActive: currentIndex == 1,
              onTap: () => onTabSelected(1),
            ),
          ),
          Expanded(
            child: _NavItem(
              icon: Icons.person_outline,
              label: 'Profil',
              isActive: currentIndex == 2,
              onTap: () => onTabSelected(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.primaryStrong : AppColors.faint;
    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Center-docked add-cat entry point (prototype's `.nav-fab`) — gate-at-
/// intent, identical mechanism to the corner fab it replaces
/// (map_screen.dart's old `_handleAddCat`): a guest's tap shows AuthGate's
/// prompt sheet first, and only pushes `/add-cat` once sign-in completes.
class _AddCatFab extends ConsumerWidget {
  const _AddCatFab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      button: true,
      label: 'Kedi ekle',
      child: Material(
        color: AppColors.primary,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _handleAddCat(context, ref),
          child: const SizedBox(
            width: _fabDiameter,
            height: _fabDiameter,
            child: Icon(Icons.add, color: AppColors.primaryInk),
          ),
        ),
      ),
    );
  }

  void _handleAddCat(BuildContext context, WidgetRef ref) {
    unawaited(
      AuthGate.require(
        context,
        ref,
        contextText: 'Kedi eklemek için giriş yap',
        intent: AnalyticsAuthIntent.addCat,
        onAuthenticated: () => context.push('/add-cat'),
      ),
    );
  }
}
