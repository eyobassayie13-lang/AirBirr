import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../services/database_service.dart';
import '../theme/app_theme.dart';

enum LedgerFilter { all, pending, synced }

/// Ledger Tab displaying complete scrollable transaction history with filtering
/// and colored indicators for incoming and outgoing payments.
class LedgerTab extends ConsumerStatefulWidget {
  const LedgerTab({super.key});

  @override
  ConsumerState<LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends ConsumerState<LedgerTab> {
  LedgerFilter _filter = LedgerFilter.all;
  List<Map<String, dynamic>> _vouchers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLedger();
    });
  }

  Future<void> _loadLedger() async {
    setState(() => _isLoading = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final list = await db.getAllVouchersHistory();
      if (mounted) {
        setState(() {
          _vouchers = list;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredVouchers {
    switch (_filter) {
      case LedgerFilter.pending:
        return _vouchers.where((v) => (v['is_synced'] as num? ?? 0) == 0).toList();
      case LedgerFilter.synced:
        return _vouchers.where((v) => (v['is_synced'] as num? ?? 0) == 1).toList();
      case LedgerFilter.all:
        return _vouchers;
    }
  }

  void _showVoucherDetails(Map<String, dynamic> v) {
    final theme = Theme.of(context);
    final isReceived = (v['direction'] ?? v['type'] ?? 'RECEIVED').toString().toUpperCase() == 'RECEIVED';
    final isSynced = (v['is_synced'] as num? ?? 0) == 1;

    final amount = (v['amount'] as num?)?.toDouble() ??
        ((v['amount_cents'] as num?)?.toDouble() ?? 0.0) / 100.0;
    final timestamp = (v['timestamp'] as num?)?.toInt() ?? 0;
    final dt = timestamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
        : DateTime.now();
    final formattedDate = DateFormat('MMM d, yyyy  HH:mm:ss').format(dt);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.subtleBorder(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              isReceived ? 'Received Payment' : 'Sent Payment',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '${isReceived ? '+' : '-'}${amount.toStringAsFixed(2)} ETB',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: isReceived ? AppColors.mint(context) : AppColors.sent(context),
              ),
            ),
            const SizedBox(height: 20),
            _buildDetailRow(context, 'Voucher ID', v['voucher_id']?.toString() ?? 'N/A'),
            _buildDetailRow(context, 'Nonce', '#${v['nonce'] ?? 0}', hasTabularFigures: true),
            _buildDetailRow(context, 'Date & Time', formattedDate, hasTabularFigures: true),
            _buildDetailRow(
              context,
              isReceived ? 'Payer Public Key' : 'Payee ID',
              isReceived
                  ? (v['payer_pubkey']?.toString() ?? 'N/A')
                  : (v['payee_id']?.toString() ?? 'N/A'),
            ),
            _buildDetailRow(
              context,
              'Sync Status',
              isSynced ? 'Synced with Central Bank' : 'Pending Sync (Offline)',
              color: isSynced ? AppColors.mint(context) : AppColors.offline(context),
            ),
            if (v['signature'] != null)
              _buildDetailRow(context, 'Signature', v['signature'].toString(), isMonospace: true),
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Close'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    String label,
    String value, {
    Color? color,
    bool isMonospace = false,
    bool hasTabularFigures = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary(context),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: color ?? AppColors.textPrimary(context),
              fontFamily: isMonospace ? 'monospace' : null,
              fontFeatures: hasTabularFigures ? const [FontFeature.tabularFigures()] : null,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surfaceColor = AppColors.surface(context);
    final subtleBorder = AppColors.subtleBorder(context);
    final mintColor = AppColors.mint(context);
    final sentColor = AppColors.sent(context);

    final filtered = _filteredVouchers;

    return Column(
      children: [
        // Pill-shaped Filter Chips ([All] [Pending] [Synced])
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              _buildFilterChip(context, 'All (${_vouchers.length})', LedgerFilter.all),
              const SizedBox(width: 8),
              _buildFilterChip(
                context,
                'Pending (${_vouchers.where((v) => (v['is_synced'] as num? ?? 0) == 0).length})',
                LedgerFilter.pending,
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                context,
                'Synced (${_vouchers.where((v) => (v['is_synced'] as num? ?? 0) == 1).length})',
                LedgerFilter.synced,
              ),
            ],
          ),
        ),

        // Transaction List
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.receipt_long_rounded,
                            size: 52,
                            color: AppColors.textTertiary(context),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _filter == LedgerFilter.pending
                                ? 'No pending vouchers to sync.'
                                : _filter == LedgerFilter.synced
                                    ? 'No synced vouchers yet.'
                                    : 'Ledger is empty. Make a payment or get paid!',
                            style: TextStyle(
                              color: AppColors.textSecondary(context),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadLedger,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        itemCount: filtered.length,
                        itemBuilder: (ctx, index) {
                          final v = filtered[index];
                          final isReceived = (v['direction'] ?? v['type'] ?? 'RECEIVED').toString().toUpperCase() == 'RECEIVED';
                          final isSynced = (v['is_synced'] as num? ?? 0) == 1;
                          final amount = (v['amount'] as num?)?.toDouble() ??
                              ((v['amount_cents'] as num?)?.toDouble() ?? 0.0) / 100.0;
                          final timestamp = (v['timestamp'] as num?)?.toInt() ?? 0;
                          final dt = timestamp > 0
                              ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
                              : DateTime.now();
                          final formattedTime = DateFormat('MMM d, HH:mm').format(dt);

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: surfaceColor,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: subtleBorder),
                            ),
                            child: ListTile(
                              onTap: () {
                                HapticFeedback.lightImpact();
                                _showVoucherDetails(v);
                              },
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              leading: Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: isReceived
                                      ? mintColor.withValues(alpha: 0.14)
                                      : sentColor.withValues(alpha: 0.14),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isReceived
                                        ? mintColor.withValues(alpha: 0.35)
                                        : sentColor.withValues(alpha: 0.35),
                                    width: 1.2,
                                  ),
                                ),
                                child: Icon(
                                  isReceived ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                                  color: isReceived ? mintColor : sentColor,
                                  size: 20,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Text(
                                    isReceived ? 'Received' : 'Sent',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isSynced
                                          ? mintColor.withValues(alpha: 0.14)
                                          : AppColors.offline(context).withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isSynced
                                            ? mintColor.withValues(alpha: 0.35)
                                            : AppColors.offline(context).withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Text(
                                      isSynced ? 'SYNCED' : 'PENDING',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: isSynced ? mintColor : AppColors.offline(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  isReceived
                                      ? 'From: ${v['payer_pubkey'] != null && v['payer_pubkey'].toString().length > 10 ? "${v['payer_pubkey'].toString().substring(0, 10)}..." : "Customer"} • $formattedTime'
                                      : 'To: ${v['payee_id'] ?? "Merchant"} • $formattedTime',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary(context),
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              trailing: Text(
                                '${isReceived ? "+" : "-"}${amount.toStringAsFixed(2)} ETB',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: isReceived ? mintColor : sentColor,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(BuildContext context, String label, LedgerFilter filter) {
    final isSelected = _filter == filter;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accentColor = AppTheme.accentColor(theme.brightness);

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() => _filter = filter);
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? accentColor.withValues(alpha: 0.18) : accentColor.withValues(alpha: 0.14))
              : AppColors.surfaceElevated(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? accentColor.withValues(alpha: 0.5) : AppColors.subtleBorder(context),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? accentColor : AppColors.textSecondary(context),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Backward compatibility alias for LedgerScreen.
typedef LedgerScreen = LedgerTab;
