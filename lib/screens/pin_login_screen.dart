import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/database_service.dart';
import '../theme/app_theme.dart';
import 'main_shell.dart';
import 'register_screen.dart';

/// Damped sinusoidal oscillation curve for natural harmonic decaying shake animation.
///
/// Models physical spring oscillation: x(t) = sin(t * count * 2π) * exp(-decay * t).
/// At t=0, offset is 0; as it shakes, it oscillates and decays smoothly to 0.
class DampedSinusoidCurve extends Curve {
  final double count;
  final double decay;

  const DampedSinusoidCurve({this.count = 3.5, this.decay = 4.2});

  @override
  double transformInternal(double t) {
    return math.sin(t * count * 2 * math.pi) * math.exp(-decay * t);
  }
}

/// 6-Digit Wallet PIN authentication screen.
///
/// Features Emil Kowalski spring micro-interactions, damped sinusoidal harmonic shake,
/// and Linear/Raycast dark craft visual aesthetic.
class PinLoginScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic>? profile;

  const PinLoginScreen({
    super.key,
    this.profile,
  });

  @override
  ConsumerState<PinLoginScreen> createState() => _PinLoginScreenState();
}

class _PinLoginScreenState extends ConsumerState<PinLoginScreen>
    with SingleTickerProviderStateMixin {
  String _enteredPin = '';
  bool _isError = false;
  bool _isVerifying = false;
  String? _errorMessage;
  String? _fetchedDisplayName;

  late final AnimationController _shakeController;

  String get _displayName {
    final fromWidget = widget.profile?['display_name']?.toString() ??
        widget.profile?['account_id']?.toString();
    if (fromWidget != null && fromWidget.isNotEmpty) {
      return fromWidget;
    }
    return _fetchedDisplayName ?? 'User';
  }

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    if (widget.profile == null || widget.profile!['display_name'] == null) {
      _loadProfile();
    }
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final profile = await db.getUserProfile();
      if (mounted && profile != null) {
        setState(() {
          _fetchedDisplayName =
              profile['display_name']?.toString() ?? profile['account_id']?.toString();
        });
      }
    } catch (_) {}
  }

  void _onDigitPressed(String digit) {
    if (_enteredPin.length >= 6 || _isVerifying) return;

    setState(() {
      _errorMessage = null;
      _isError = false;
      _enteredPin += digit;
    });

    if (_enteredPin.length == 6) {
      _verifyPin();
    }
  }

  void _onBackspacePressed() {
    if (_enteredPin.isEmpty || _isVerifying) return;

    HapticFeedback.lightImpact();
    setState(() {
      _errorMessage = null;
      _isError = false;
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
    });
  }

  Future<void> _verifyPin() async {
    setState(() => _isVerifying = true);

    try {
      const storage = FlutterSecureStorage();
      final storedPin = await storage.read(key: 'user_wallet_pin');

      if (storedPin != null && storedPin == _enteredPin) {
        // MATCH: Light tactile feedback and navigate to MainShellScreen
        await HapticFeedback.lightImpact();
        if (!mounted) return;

        final db = ref.read(databaseServiceProvider);
        final profile = widget.profile ?? await db.getUserProfile() ?? {};
        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MainShellScreen(profile: profile),
          ),
        );
      } else {
        // MISMATCH: Harmonic decaying shake oscillation, red flash, and tactile vibration
        await HapticFeedback.vibrate();
        if (!mounted) return;

        setState(() {
          _isError = true;
          _errorMessage = 'Incorrect PIN. Try again.';
        });

        _shakeController.forward(from: 0.0);

        await Future.delayed(const Duration(milliseconds: 600));

        if (mounted) {
          setState(() {
            _enteredPin = '';
            _isError = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Verification failed: $e';
          _enteredPin = '';
          _isError = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _showResetWalletDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Wallet?'),
        content: const Text(
          'This will remove your local security PIN and profile from this device. '
          'Your cryptographic key seed and offline ledger remain secure. '
          'Are you sure you want to proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentRed,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset Wallet'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      const storage = FlutterSecureStorage();
      await storage.delete(key: 'user_wallet_pin');

      final db = ref.read(databaseServiceProvider);
      await db.clearUserProfile();

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const RegisterScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final accentColor = AppTheme.accentColor(brightness);
    final scaffoldBg = isDark ? const Color(0xFF0D0D0E) : AppTheme.lightBackground;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Centered AirBirr Branding with ambient glow
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [accentColor, AppTheme.darkMintGreen],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: isDark ? 0.35 : 0.25),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.currency_exchange_rounded,
                      size: 30,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Text(
                    'AirBirr',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Greeting: "Welcome back, [DisplayName]"
                  Text(
                    'Welcome back, $_displayName',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Enter your 6-digit Wallet PIN to unlock',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 22),

                  // 6 Circular PIN Dot Indicators with Spring Expansion & Decaying Shake
                  AnimatedBuilder(
                    animation: _shakeController,
                    builder: (context, child) {
                      final dx = const DampedSinusoidCurve().transform(_shakeController.value) * 18.0;
                      return Transform.translate(
                        offset: Offset(dx, 0),
                        child: child,
                      );
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(6, (index) {
                        return _PinDot(
                          isFilled: index < _enteredPin.length,
                          isError: _isError,
                          brightness: brightness,
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Error Text with clean constraint
                  SizedBox(
                    height: 20,
                    child: _errorMessage != null
                        ? Text(
                            _errorMessage!,
                            key: const Key('pin_error_text'),
                            style: const TextStyle(
                              color: AppColors.accentRed,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 14),

                  // Glassmorphic Card Contour for Keypad Area (Linear/Raycast aesthetic)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF131316).withValues(alpha: 0.90)
                          : Colors.white.withValues(alpha: 0.90),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.06),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _KeypadButton(
                              label: '1',
                              buttonKey: const Key('keypad_1'),
                              onTap: () => _onDigitPressed('1'),
                            ),
                            _KeypadButton(
                              label: '2',
                              buttonKey: const Key('keypad_2'),
                              onTap: () => _onDigitPressed('2'),
                            ),
                            _KeypadButton(
                              label: '3',
                              buttonKey: const Key('keypad_3'),
                              onTap: () => _onDigitPressed('3'),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _KeypadButton(
                              label: '4',
                              buttonKey: const Key('keypad_4'),
                              onTap: () => _onDigitPressed('4'),
                            ),
                            _KeypadButton(
                              label: '5',
                              buttonKey: const Key('keypad_5'),
                              onTap: () => _onDigitPressed('5'),
                            ),
                            _KeypadButton(
                              label: '6',
                              buttonKey: const Key('keypad_6'),
                              onTap: () => _onDigitPressed('6'),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _KeypadButton(
                              label: '7',
                              buttonKey: const Key('keypad_7'),
                              onTap: () => _onDigitPressed('7'),
                            ),
                            _KeypadButton(
                              label: '8',
                              buttonKey: const Key('keypad_8'),
                              onTap: () => _onDigitPressed('8'),
                            ),
                            _KeypadButton(
                              label: '9',
                              buttonKey: const Key('keypad_9'),
                              onTap: () => _onDigitPressed('9'),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Empty placeholder for keypad grid symmetry
                            const SizedBox(width: 62 + 16, height: 62 + 10),
                            _KeypadButton(
                              label: '0',
                              buttonKey: const Key('keypad_0'),
                              onTap: () => _onDigitPressed('0'),
                            ),
                            _KeypadButton(
                              label: '⌫',
                              buttonKey: const Key('keypad_backspace'),
                              customChild: Icon(
                                Icons.backspace_outlined,
                                size: 20,
                                color: isDark ? const Color(0xFFEDEDED) : const Color(0xFF1F2937),
                              ),
                              onTap: _onBackspacePressed,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Bottom Text Button: "Reset Wallet" (Separated with generous spacing away from Android gesture bar)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: TextButton.icon(
                      key: const Key('reset_wallet_button'),
                      onPressed: _showResetWalletDialog,
                      icon: const Icon(Icons.refresh_rounded, size: 15),
                      label: const Text(
                        'Reset Wallet',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// PIN Dot with active spring expansion on fill and luminous glow.
class _PinDot extends StatelessWidget {
  final bool isFilled;
  final bool isError;
  final Brightness brightness;

  const _PinDot({
    required this.isFilled,
    required this.isError,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = brightness == Brightness.dark;
    final Color dotColor = isError
        ? AppColors.accentRed
        : (isFilled ? AppTheme.darkPrimaryAccent : Colors.transparent);
    final Color borderColor = isError
        ? AppColors.accentRed
        : (isFilled
            ? AppTheme.darkPrimaryAccent
            : (isDark ? Colors.white.withValues(alpha: 0.16) : Colors.black.withValues(alpha: 0.18)));

    return AnimatedScale(
      scale: isFilled ? 1.08 : 0.88,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: borderColor,
            width: 1.8,
          ),
          boxShadow: [
            if (isError)
              BoxShadow(
                color: AppColors.accentRed.withValues(alpha: 0.55),
                blurRadius: 10,
                spreadRadius: 1,
              )
            else if (isFilled)
              BoxShadow(
                color: AppTheme.darkPrimaryAccent.withValues(alpha: 0.45),
                blurRadius: 8,
                spreadRadius: 1,
              ),
          ],
        ),
      ),
    );
  }
}

/// Numpad Key with natural spring scale feedback (scale down to 0.92 on press,
/// bounce back with spring damping ratio ~0.7) and instant haptic feedback.
class _KeypadButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Widget? customChild;
  final Key? buttonKey;

  const _KeypadButton({
    required this.label,
    required this.onTap,
    this.customChild,
    this.buttonKey,
  });

  @override
  State<_KeypadButton> createState() => _KeypadButtonState();
}

class _KeypadButtonState extends State<_KeypadButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final surfaceColor = isDark
        ? const Color(0xFF18181C)
        : const Color(0xFFF1F3F5);
    final borderColor = isDark
        ? const Color(0x1FFFFFFF)
        : const Color(0xFFE2E8F0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: widget.buttonKey,
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onTap();
          },
          onHighlightChanged: (highlighted) {
            setState(() => _isPressed = highlighted);
          },
          borderRadius: BorderRadius.circular(36),
          child: AnimatedScale(
            scale: _isPressed ? 0.92 : 1.0,
            duration: Duration(milliseconds: _isPressed ? 70 : 220),
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: Duration(milliseconds: _isPressed ? 70 : 220),
              curve: Curves.easeOutBack,
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: surfaceColor,
                border: Border.all(color: borderColor, width: 1.2),
                boxShadow: [
                  if (isDark)
                    BoxShadow(
                      color: Colors.black.withValues(alpha: _isPressed ? 0.15 : 0.35),
                      blurRadius: _isPressed ? 4 : 10,
                      offset: Offset(0, _isPressed ? 1 : 3),
                    )
                  else
                    BoxShadow(
                      color: Colors.black.withValues(alpha: _isPressed ? 0.02 : 0.05),
                      blurRadius: _isPressed ? 3 : 8,
                      offset: Offset(0, _isPressed ? 1 : 2),
                    ),
                ],
              ),
              alignment: Alignment.center,
              child: widget.customChild ??
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      fontFamily: 'monospace',
                      color: isDark ? const Color(0xFFEDEDED) : const Color(0xFF1F2937),
                      letterSpacing: -0.5,
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
