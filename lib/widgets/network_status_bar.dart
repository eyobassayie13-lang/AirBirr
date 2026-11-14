import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Persistent Network Status Banner displayed at the top of the app.
///
/// Features fluid animated size/opacity transitions between online (subtle emerald aura)
/// and offline (warm ambient amber) states, matching Linear/Stripe design standards.
class NetworkStatusBar extends StatelessWidget {
  final bool isOnline;

  const NetworkStatusBar({
    super.key,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final Color backgroundColor = isOnline
        ? (isDark ? const Color(0xFF0E2318) : const Color(0xFFE8F5E9))
        : (isDark ? const Color(0xFF281F0E) : const Color(0xFFFFF8E1));

    final Color textColor = isOnline
        ? AppTheme.onlineColor(brightness)
        : AppTheme.offlineColor(brightness);

    final Color borderColor = isOnline
        ? AppTheme.onlineColor(brightness).withValues(alpha: isDark ? 0.25 : 0.20)
        : AppTheme.offlineColor(brightness).withValues(alpha: isDark ? 0.35 : 0.25);

    final IconData iconData = isOnline
        ? Icons.cloud_done_rounded
        : Icons.cloud_off_rounded;

    final String message = isOnline
        ? 'Connected to Central Bank'
        : 'Offline Mode Active (Autonomous Vault)';

    return AnimatedContainer(
      key: const Key('network_status_bar'),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: borderColor,
            width: 1,
          ),
        ),
        boxShadow: [
          if (isOnline)
            BoxShadow(
              color: AppTheme.onlineColor(brightness).withValues(alpha: isDark ? 0.08 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            )
          else
            BoxShadow(
              color: AppTheme.offlineColor(brightness).withValues(alpha: isDark ? 0.08 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.center,
              child: child,
            ),
          );
        },
        child: Row(
          key: ValueKey<bool>(isOnline),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              iconData,
              size: 16,
              color: textColor,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
