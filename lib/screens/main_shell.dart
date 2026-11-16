import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../services/api_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import '../widgets/network_status_bar.dart';
import 'home_tab.dart';
import 'ledger_tab.dart';
import 'pin_login_screen.dart';
import 'receive_tab.dart';
import 'register_screen.dart';
import 'send_tab.dart';

/// Main Shell Screen featuring Persistent Top Status Banner, Material 3 NavigationBar,
/// and Top AppBar with Cloud Sync badge and Settings options.
class MainShellScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> profile;

  const MainShellScreen({
    super.key,
    required this.profile,
  });

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  int _currentIndex = 0;
  bool _isOnline = true;
  Timer? _connectivityTimer;
  int _unsyncedCount = 0;
  bool _isSyncing = false;

  String get _displayName =>
      widget.profile['display_name']?.toString() ??
      widget.profile['account_id']?.toString() ??
      'User';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerConnectivity();
      _refreshUnsyncedCount();
    });

    if (!WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
      _connectivityTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _checkServerConnectivity();
        _refreshUnsyncedCount();
      });
    }
  }

  @override
  void dispose() {
    _connectivityTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkServerConnectivity() async {
    try {
      final api = ref.read(apiServiceProvider);
      final isHealthy = await api.checkHealth();
      if (mounted && _isOnline != isHealthy) {
        setState(() => _isOnline = isHealthy);
      }
    } catch (_) {
      if (mounted && _isOnline) {
        setState(() => _isOnline = false);
      }
    }
  }

  Future<void> _refreshUnsyncedCount() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final list = await db.getUnsyncedVouchers();
      if (mounted && _unsyncedCount != list.length) {
        setState(() => _unsyncedCount = list.length);
      }
    } catch (_) {}
  }

  Future<void> _syncWithCentralBank() async {
    if (_isSyncing) return; // Prevent double-tap race condition
    if (!_isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cannot sync while offline. Reconnect to Central Bank.'),
          backgroundColor: AppColors.offline(context),
        ),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseServiceProvider);
    final api = ref.read(apiServiceProvider);
    final mintColor = AppColors.mint(context);
    final sentColor = AppColors.sent(context);

    setState(() => _isSyncing = true);

    try {
      final unsynced = await db.getUnsyncedVouchers();
      if (unsynced.isEmpty) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(
              content: const Text('No pending offline vouchers to sync.'),
              backgroundColor: mintColor,
            ),
          );
        }
        return;
      }

      final settledIds = await api.uploadBatchVouchers(unsynced);
      if (settledIds.isNotEmpty) {
        await db.markVouchersSynced(settledIds);
        if (!mounted) return;
        await _refreshUnsyncedCount();

        messenger.showSnackBar(
          SnackBar(
            content: Text('Synced ${settledIds.length} vouchers with Central Bank!'),
            backgroundColor: mintColor,
          ),
        );
      } else {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Sync failed or no vouchers cleared by clearinghouse.'),
            backgroundColor: sentColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Sync Error: $e'),
            backgroundColor: sentColor,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _showSettingsDialog() async {
    final api = ref.read(apiServiceProvider);
    final db = ref.read(databaseServiceProvider);

    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Central Bank Server Settings'),
                subtitle: Text(api.baseUrl, style: const TextStyle(fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final newUrl = await showDialog<String>(
                    context: context,
                    builder: (_) => ServerSettingsDialog(initialUrl: api.baseUrl),
                  );
                  if (newUrl != null && newUrl.isNotEmpty && mounted) {
                    api.setBaseUrl(newUrl);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Server URL set to: $newUrl')),
                    );
                    _checkServerConnectivity();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Reset Wallet / Switch Account'),
                subtitle: const Text('Clears local profile and returns to onboarding', style: TextStyle(fontSize: 12)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (alertCtx) => AlertDialog(
                      title: const Text('Reset Wallet Registration?'),
                      content: const Text(
                        'This will clear your stored user profile on this device and return to registration. Your ledger history is preserved.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(alertCtx, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(alertCtx, true),
                          child: const Text('Reset Profile'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true && mounted) {
                    await db.clearUserProfile();
                    if (!mounted) return;
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const RegisterScreen()),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = AppTheme.accentColor(brightness);

    final tabs = [
      HomeTab(
        key: const PageStorageKey('home_tab'),
        profile: widget.profile,
        isOnline: _isOnline,
        onNavigateToSend: () => setState(() => _currentIndex = 1),
        onNavigateToReceive: () => setState(() => _currentIndex = 2),
        onNavigateToLedger: () => setState(() => _currentIndex = 3),
      ),
      SendTab(
        key: const PageStorageKey('send_tab'),
        profile: widget.profile,
        onPaymentCompleted: _refreshUnsyncedCount,
      ),
      ReceiveTab(
        key: const PageStorageKey('receive_tab'),
        profile: widget.profile,
        onPaymentReceived: _refreshUnsyncedCount,
      ),
      const LedgerTab(
        key: PageStorageKey('ledger_tab'),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hello, $_displayName',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              widget.profile['is_merchant'] == true ? 'AirBirr Merchant' : 'AirBirr Personal',
              style: TextStyle(
                fontSize: 11,
                color: theme.textTheme.bodySmall?.color,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        actions: [
          // Cloud Sync icon with Badge of unsynced vouchers (muted when offline)
          Badge(
            isLabelVisible: _unsyncedCount > 0,
            label: Text(
              '$_unsyncedCount',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            backgroundColor: _isOnline ? AppColors.offline(context) : const Color(0xFF9E9E9E),
            textColor: isDark ? Colors.black : Colors.white,
            offset: const Offset(-4, 4),
            child: IconButton(
              key: const Key('cloud_sync_button'),
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync),
              tooltip: _isOnline ? 'Sync Offline Vouchers' : 'Sync Unavailable (Offline)',
              color: _isOnline ? accentColor : const Color(0xFF9E9E9E),
              disabledColor: const Color(0xFF9E9E9E),
              onPressed: _isOnline && !_isSyncing ? _syncWithCentralBank : null,
            ),
          ),

          // Lock Wallet button
          IconButton(
            key: const Key('lock_wallet_button'),
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock Wallet',
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => PinLoginScreen(profile: widget.profile),
                ),
              );
            },
          ),

          // Settings icon
          IconButton(
            key: const Key('server_settings_button'),
            icon: const Icon(Icons.settings),
            tooltip: 'Server Settings',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // Persistent Top Status Banner (Amber for offline, Mint Green for online)
          NetworkStatusBar(isOnline: _isOnline),

          // Active Tab Screen
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: tabs,
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() {
            _currentIndex = idx;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.send_outlined),
            selectedIcon: Icon(Icons.send_rounded),
            label: 'Send',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_2_outlined),
            selectedIcon: Icon(Icons.qr_code_2_rounded),
            label: 'Receive',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: 'Ledger',
          ),
        ],
      ),
    );
  }
}

/// Backward compatibility alias for MainNavigationShell.
typedef MainNavigationShell = MainShellScreen;
