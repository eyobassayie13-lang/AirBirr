import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../services/crypto_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';

/// Home Dashboard Tab displaying Offline Vault Balance, Nonce Counter,
/// Public Key chip, and Offline Spending Allowance Leaser.
class HomeTab extends ConsumerStatefulWidget {
  final Map<String, dynamic> profile;
  final bool isOnline;
  final VoidCallback? onNavigateToSend;
  final VoidCallback? onNavigateToReceive;
  final VoidCallback? onNavigateToLedger;

  const HomeTab({
    super.key,
    required this.profile,
    this.isOnline = true,
    this.onNavigateToSend,
    this.onNavigateToReceive,
    this.onNavigateToLedger,
  });

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  double _balance = 0.0;
  int _nonce = 0;
  String? _activeLeaseId;
  String? _publicKeyBase64;
  bool _isLoading = true;

  int _sentCount = 0;
  int _receivedCount = 0;
  int _unsyncedCount = 0;
  List<Map<String, dynamic>> _recentTransactions = [];

  bool _isKeyCopied = false;
  bool _isLeasing = false;
  bool _isSyncing = false;
  Timer? _copyTimer;

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDashboardData();
    });
  }

  Future<void> _loadDashboardData() async {
    setState(() => _isLoading = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final crypto = ref.read(cryptoServiceProvider);

      var state = await db.getWalletState();
      final currentBalanceCents = (state['offline_balance_cents'] as num?)?.toInt() ?? 0;
      final activeLeaseId = state['active_lease_id'] as String?;

      // Auto-seed initial test balance of 1M ETB if balance is 0 and lease is null/empty
      if (currentBalanceCents == 0 && (activeLeaseId == null || activeLeaseId.isEmpty)) {
        await db.initWalletState(
          initialBalanceCents: DatabaseService.defaultInitialBalanceCents,
          leaseId: DatabaseService.defaultInitialLeaseId,
        );
        state = await db.getWalletState();
      }

      final pubKey = await crypto.getPublicKeyBase64();
      final history = await db.getAllVouchersHistory();
      final unsynced = await db.getUnsyncedVouchers();

      int sent = 0;
      int received = 0;
      for (final v in history) {
        final dir = (v['direction'] ?? v['type'] ?? 'RECEIVED').toString().toUpperCase();
        if (dir == 'SENT') {
          sent++;
        } else {
          received++;
        }
      }

      if (mounted) {
        setState(() {
          _balance = (state['offline_balance_cents'] as num? ?? 0) / 100.0;
          _nonce = (state['current_nonce'] as num? ?? 0).toInt();
          _activeLeaseId = state['active_lease_id'] as String?;
          _publicKeyBase64 = pubKey;
          _sentCount = sent;
          _receivedCount = received;
          _unsyncedCount = unsynced.length;
          _recentTransactions = history.take(3).toList();
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showLeaseAllowanceDialog() async {
    if (!widget.isOnline) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.cloud_off_rounded, color: AppColors.offline(context), size: 36),
          title: const Text('Connection Required'),
          content: const Text(
            'Leasing offline spending allowance locks funds from your Central Bank account into your offline vault.\n\n'
            'This action requires network connectivity. Connect to the internet or Wi-Fi to lease allowance.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      return;
    }
    final amountController = TextEditingController(text: '300.00');
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lock Offline Spending Allowance'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This locks funds from your Central Bank account into an offline vault valid for offline spending.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('lease_amount_input'),
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              decoration: const InputDecoration(
                labelText: 'Amount (ETB)',
                suffixText: 'ETB',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_lease_button'),
            onPressed: () {
              final val = double.tryParse(amountController.text.trim());
              if (val != null && val > 0) {
                Navigator.pop(ctx, val);
              }
            },
            child: const Text('Confirm & Lock'),
          ),
        ],
      ),
    );

    if (result != null && result > 0 && mounted) {
      await _executeLeaseAllowance(result);
    }
  }

  Future<void> _executeLeaseAllowance(double amount) async {
    if (_isLeasing) return; // Prevent double-tap race condition
    setState(() => _isLeasing = true);

    final messenger = ScaffoldMessenger.of(context);
    final api = ref.read(apiServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final accountId = widget.profile['account_id']?.toString() ?? 'default_account';

    try {
      final leaseResponse = await api.requestOfflineLease(
        accountId: accountId,
        amount: amount,
      );

      if (!mounted) return;

      if (leaseResponse != null && leaseResponse['error'] == null) {
        final leaseId = leaseResponse['lease_id']?.toString() ?? 'lease_${DateTime.now().millisecondsSinceEpoch}';
        final leasedAmount = (leaseResponse['amount_leased'] as num?)?.toDouble() ?? amount;

        await db.applyOfflineLease(
          leaseId: leaseId,
          leasedAmount: leasedAmount,
        );

        if (!mounted) return;
        await _loadDashboardData();

        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '[VAULT FUNDED] Leased ${leasedAmount.toStringAsFixed(2)} ETB from Central Bank!',
            ),
            backgroundColor: AppTheme.darkMintGreen,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        final errMsg = leaseResponse?['error']?.toString() ?? 'Failed to issue lease from Central Bank.';
        messenger.showSnackBar(
          SnackBar(
            content: Text(errMsg),
            backgroundColor: AppTheme.darkError,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Lease Error: $e'),
            backgroundColor: AppTheme.darkError,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLeasing = false);
    }
  }

  Future<void> _syncVouchers() async {
    if (_isSyncing) return;
    if (!widget.isOnline) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.cloud_off_rounded, color: AppColors.offline(context), size: 36),
          title: const Text('Offline: Sync Paused'),
          content: Text(
            'You have $_unsyncedCount offline voucher${_unsyncedCount == 1 ? '' : 's'} cryptographically secured in your device ledger.\n\n'
            'They are safely stored and will automatically settle with the Central Bank clearinghouse once your connection is restored.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() => _isSyncing = true);
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseServiceProvider);
    final api = ref.read(apiServiceProvider);

    try {
      final unsynced = await db.getUnsyncedVouchers();
      if (unsynced.isEmpty) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('All vouchers already synced with Central Bank.'),
              backgroundColor: Colors.teal,
            ),
          );
        }
        return;
      }

      final settledIds = await api.uploadBatchVouchers(unsynced);
      if (settledIds.isNotEmpty) {
        await db.markVouchersSynced(settledIds);
        if (!mounted) return;
        await _loadDashboardData();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Synced ${settledIds.length} vouchers with Central Bank!'),
            backgroundColor: AppTheme.darkMintGreen,
          ),
        );
      } else {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Sync failed or no vouchers cleared by clearinghouse.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Sync Error: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _copyPublicKey() {
    if (_publicKeyBase64 != null) {
      HapticFeedback.lightImpact();
      Clipboard.setData(ClipboardData(text: _publicKeyBase64!));
      _copyTimer?.cancel();
      setState(() => _isKeyCopied = true);
      _copyTimer = Timer(const Duration(milliseconds: 2000), () {
        if (mounted) setState(() => _isKeyCopied = false);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Public key copied to clipboard!'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final accentColor = AppTheme.accentColor(brightness);
    final mintColor = AppColors.mint(context);
    final sentColor = AppColors.sent(context);
    final surfaceColor = AppColors.surface(context);
    final elevatedSurface = AppColors.surfaceElevated(context);
    final borderColor = AppColors.border(context);
    final subtleBorder = AppColors.subtleBorder(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadDashboardData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. HERO VAULT CARD (Sleek elevated gradient vault card with subtle border glow)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: mintColor.withValues(alpha: isDark ? 0.12 : 0.06),
                    blurRadius: 28,
                    spreadRadius: 0,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: isDark
                        ? mintColor.withValues(alpha: 0.22)
                        : borderColor,
                    width: 1.2,
                  ),
                ),
                color: surfaceColor,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    children: [
                      // Ambient radiant glow at top-right
                      Positioned(
                        top: -40,
                        right: -40,
                        child: Container(
                          width: 160,
                          height: 160,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                mintColor.withValues(alpha: isDark ? 0.18 : 0.10),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(22.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header Row: Vault Badge & Nonce / Lease Pills
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: accentColor.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        Icons.shield_rounded,
                                        color: accentColor,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Offline Vault',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: AppColors.textPrimary(context),
                                            letterSpacing: 0.2,
                                          ),
                                        ),
                                        Text(
                                          'Autonomous Ledger',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textSecondary(context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                // Nonce & Active Lease Badge Pills
                                Row(
                                  children: [
                                    if (_activeLeaseId != null && _activeLeaseId!.isNotEmpty) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        margin: const EdgeInsets.only(right: 6),
                                        decoration: BoxDecoration(
                                          color: mintColor.withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: mintColor.withValues(alpha: 0.35)),
                                        ),
                                        child: Text(
                                          'CB Leased',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: mintColor,
                                          ),
                                        ),
                                      ),
                                    ],
                                    Tooltip(
                                      message: 'Sequential transaction sequence counter (Nonce #$_nonce)',
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.offline(context).withValues(alpha: 0.14),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: AppColors.offline(context).withValues(alpha: 0.40)),
                                        ),
                                        child: Text(
                                          'Offline Tx: #$_nonce',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.offline(context),
                                            fontFeatures: const [FontFeature.tabularFigures()],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),

                            // Bold Tabular Balance in ETB
                            Text(
                              '${_balance.toStringAsFixed(2)} ETB',
                              key: const Key('wallet_balance_text'),
                              style: TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w900,
                                color: mintColor,
                                letterSpacing: -0.8,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 14),

                            // Tap-to-Copy Public Key Pill
                            InkWell(
                              onTap: _copyPublicKey,
                              borderRadius: BorderRadius.circular(10),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: _isKeyCopied
                                      ? mintColor.withValues(alpha: isDark ? 0.14 : 0.08)
                                      : elevatedSurface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: _isKeyCopied
                                        ? mintColor.withValues(alpha: 0.45)
                                        : subtleBorder,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 250),
                                      child: _isKeyCopied
                                          ? Icon(
                                              Icons.check_circle_rounded,
                                              key: const ValueKey('copied_key_icon'),
                                              size: 14,
                                              color: mintColor,
                                            )
                                          : Icon(
                                              Icons.key_rounded,
                                              key: const ValueKey('default_key_icon'),
                                              size: 14,
                                              color: accentColor,
                                            ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        _publicKeyBase64 != null
                                            ? 'Key: ${_publicKeyBase64!.substring(0, 10)}...${_publicKeyBase64!.substring(_publicKeyBase64!.length - 8)}'
                                            : 'Public Key',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          fontFeatures: const [FontFeature.tabularFigures()],
                                          fontWeight: FontWeight.w500,
                                          color: _isKeyCopied
                                              ? mintColor
                                              : AppColors.textSecondary(context),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 250),
                                      child: _isKeyCopied
                                          ? Icon(
                                              Icons.done_all_rounded,
                                              key: const ValueKey('copied_done_icon'),
                                              size: 12,
                                              color: mintColor,
                                            )
                                          : Icon(
                                              Icons.copy_rounded,
                                              key: const ValueKey('default_copy_icon'),
                                              size: 12,
                                              color: AppColors.textTertiary(context),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 2. QUICK ACTIONS ROW ([Send], [Receive], [Lease], [Sync])
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildCircularActionButton(
                  context,
                  icon: Icons.arrow_upward_rounded,
                  label: 'Send ETB',
                  color: accentColor,
                  onTap: widget.onNavigateToSend ?? () {},
                ),
                _buildCircularActionButton(
                  context,
                  icon: Icons.arrow_downward_rounded,
                  label: 'Receive ETB',
                  color: mintColor,
                  onTap: widget.onNavigateToReceive ?? () {},
                ),
                _buildCircularActionButton(
                  context,
                  buttonKey: const Key('lease_allowance_button'),
                  icon: Icons.lock_clock_rounded,
                  label: 'Lease',
                  tooltip: 'Lease Offline Allowance',
                  color: widget.isOnline ? Colors.amber : const Color(0xFF9E9E9E),
                  isDisabled: !widget.isOnline,
                  onTap: _showLeaseAllowanceDialog,
                ),
                _buildCircularActionButton(
                  context,
                  icon: _isSyncing ? Icons.hourglass_top_rounded : Icons.sync_rounded,
                  label: 'Sync',
                  tooltip: 'Sync Offline Vouchers',
                  color: widget.isOnline ? mintColor : const Color(0xFF9E9E9E),
                  isDisabled: !widget.isOnline,
                  onTap: _syncVouchers,
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 3. QUICK STATISTICS
            Text(
              'Ledger Activity',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary(context),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildStatCard(
                  context,
                  title: 'Received',
                  value: '$_receivedCount',
                  icon: Icons.call_received_rounded,
                  color: mintColor,
                  onTap: widget.onNavigateToLedger ?? () {},
                ),
                const SizedBox(width: 10),
                _buildStatCard(
                  context,
                  title: 'Sent',
                  value: '$_sentCount',
                  icon: Icons.call_made_rounded,
                  color: sentColor,
                  onTap: widget.onNavigateToLedger ?? () {},
                ),
                const SizedBox(width: 10),
                _buildStatCard(
                  context,
                  title: 'Unsynced',
                  value: '$_unsyncedCount',
                  icon: Icons.cloud_queue_rounded,
                  color: AppColors.offline(context),
                  onTap: widget.onNavigateToLedger ?? () {},
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 4. RECENT ACTIVITY PREVIEW (Latest 3 transactions right on Home)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Activity',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary(context),
                  ),
                ),
                if (widget.onNavigateToLedger != null)
                  TextButton(
                    onPressed: widget.onNavigateToLedger,
                    style: TextButton.styleFrom(
                      foregroundColor: accentColor,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('See all', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        SizedBox(width: 2),
                        Icon(Icons.chevron_right_rounded, size: 16),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            if (_recentTransactions.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 38,
                      color: AppColors.textTertiary(context),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No offline transactions yet',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Send or receive offline payment to see activity here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary(context),
                      ),
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _recentTransactions.length,
                itemBuilder: (ctx, index) {
                  final v = _recentTransactions[index];
                  final isReceived = (v['direction'] ?? v['type'] ?? 'RECEIVED').toString().toUpperCase() == 'RECEIVED';
                  final isSynced = (v['is_synced'] as num? ?? 0) == 1;
                  final amount = (v['amount'] as num?)?.toDouble() ??
                      ((v['amount_cents'] as num?)?.toDouble() ?? 0.0) / 100.0;
                  final timestamp = (v['timestamp'] as num?)?.toInt() ?? 0;
                  final dt = timestamp > 0
                      ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
                      : DateTime.now();
                  final formattedTime = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                  final title = isReceived
                      ? (v['payer_pubkey'] != null && v['payer_pubkey'].toString().length > 10
                          ? 'From: ${v['payer_pubkey'].toString().substring(0, 8)}...'
                          : 'Incoming Payment')
                      : 'To: ${v['payee_id'] ?? "Merchant"}';

                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: subtleBorder),
                    ),
                    color: surfaceColor,
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                      onTap: widget.onNavigateToLedger,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: (isReceived ? mintColor : sentColor).withValues(alpha: 0.15),
                        child: Icon(
                          isReceived ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                          color: isReceived ? mintColor : sentColor,
                          size: 18,
                        ),
                      ),
                      title: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppColors.textPrimary(context),
                        ),
                      ),
                      subtitle: Text(
                        formattedTime,
                        style: TextStyle(
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${isReceived ? "+" : "-"}${amount.toStringAsFixed(2)} ETB',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              color: isReceived ? mintColor : sentColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: isSynced
                                  ? mintColor.withValues(alpha: 0.15)
                                  : AppColors.offline(context).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isSynced ? 'SYNCED' : 'PENDING',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                color: isSynced ? mintColor : AppColors.offline(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildCircularActionButton(
    BuildContext context, {
    Key? buttonKey,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    String? tooltip,
    bool isDisabled = false,
  }) {
    final elevatedSurface = AppColors.surfaceElevated(context);
    final subtleBorder = AppColors.subtleBorder(context);

    return Tooltip(
      message: tooltip ?? label,
      child: InkWell(
        key: buttonKey,
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDisabled
                      ? (AppColors.isDark(context) ? const Color(0xFF1E1E1E) : const Color(0xFFEEEEEE))
                      : elevatedSurface,
                  border: Border.all(
                    color: isDisabled ? subtleBorder : color.withValues(alpha: 0.28),
                    width: 1.2,
                  ),
                  boxShadow: [
                    if (!isDisabled)
                      BoxShadow(
                        color: color.withValues(alpha: 0.14),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    icon,
                    color: isDisabled ? const Color(0xFF9E9E9E) : color,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDisabled ? const Color(0xFF9E9E9E) : AppColors.textPrimary(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    final surfaceColor = AppColors.surface(context);
    final subtleBorder = AppColors.subtleBorder(context);

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: subtleBorder),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Backward compatibility alias for HomeScreen.
typedef HomeScreen = HomeTab;
