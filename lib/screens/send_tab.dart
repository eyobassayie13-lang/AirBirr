import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/crypto_service.dart';
import '../services/database_service.dart';
import '../services/nearby_service.dart';
import '../theme/app_theme.dart';
import '../widgets/qr_scanner_screen.dart';

enum SendMode { qr, nearby }

/// Send Tab allowing customers to pay offline via QR code scanning or BLE Nearby discovery.
///
/// Prompts amount with "Simulate Tampering" option, signs voucher deterministically
/// using Ed25519, transmits to the merchant, and awaits a two-way ACK/NACK response
/// before debiting local balance.
class SendTab extends ConsumerStatefulWidget {
  final Map<String, dynamic> profile;
  final VoidCallback? onPaymentCompleted;

  const SendTab({
    super.key,
    required this.profile,
    this.onPaymentCompleted,
  });

  @override
  ConsumerState<SendTab> createState() => _SendTabState();
}

class _SendTabState extends ConsumerState<SendTab> with SingleTickerProviderStateMixin {
  SendMode _mode = SendMode.qr;

  // Nearby Discovery State
  bool _isDiscovering = false;
  final Map<String, String> _discoveredEndpoints = {};
  final Map<String, String> _endpointPublicKeys = {};
  bool _isSending = false;
  String? _successBanner;

  String? _myPublicKeyBase64;
  double _currentBalance = 0.0;

  late AnimationController _radarController;
  late Animation<double> _radarAnimation;

  @visibleForTesting
  String? get myPublicKeyBase64 => _myPublicKeyBase64;

  String get _currentAccountName =>
      widget.profile['display_name']?.toString() ??
      widget.profile['account_id']?.toString() ??
      'Customer-Wallet';

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _radarAnimation = CurvedAnimation(
      parent: _radarController,
      curve: Curves.easeInOut,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshWalletData();
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    try {
      ref.read(nearbyServiceProvider).stopAll();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _refreshWalletData() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final crypto = ref.read(cryptoServiceProvider);

      final state = await db.getWalletState();
      final pubKey = await crypto.getPublicKeyBase64();

      if (mounted) {
        setState(() {
          _currentBalance = (state['offline_balance_cents'] as num? ?? 0) / 100.0;
          _myPublicKeyBase64 = pubKey;
        });
      }
    } catch (_) {}
  }

  // ===========================================================================
  // NEARBY DISCOVERY CONTROLS
  // ===========================================================================

  Future<void> _toggleDiscovery() async {
    final nearby = ref.read(nearbyServiceProvider);
    await HapticFeedback.lightImpact();

    if (_isDiscovering) {
      await nearby.stopDiscovery();
      _radarController.stop();
      _radarController.reset();
      if (mounted) {
        setState(() {
          _isDiscovering = false;
          _discoveredEndpoints.clear();
          _endpointPublicKeys.clear();
        });
      }
    } else {
      setState(() {
        _discoveredEndpoints.clear();
        _endpointPublicKeys.clear();
      });

      final success = await nearby.startDiscovery(
        userName: _currentAccountName,
        onEndpointFound: (endpointId, rawEndpointName) {
          final parts = rawEndpointName.split('|');
          final displayName = parts[0];
          final endpointPubKey = parts.length > 1 ? parts[1] : '';

          // Ignore self-device
          if (_myPublicKeyBase64 != null && endpointPubKey == _myPublicKeyBase64) {
            return;
          }

          if (mounted) {
            setState(() {
              _discoveredEndpoints[endpointId] = displayName;
              if (endpointPubKey.isNotEmpty) {
                _endpointPublicKeys[endpointId] = endpointPubKey;
              }
            });
          }
        },
        onEndpointLost: (endpointId) {
          if (mounted) {
            setState(() {
              _discoveredEndpoints.remove(endpointId);
              _endpointPublicKeys.remove(endpointId);
            });
          }
        },
      );

      if (mounted) {
        if (success) {
          _radarController.repeat(reverse: true);
        } else {
          _radarController.stop();
          _radarController.reset();
        }
        setState(() {
          _isDiscovering = success;
        });
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to start Bluetooth discovery. Check permissions.')),
          );
        }
      }
    }
  }

  // ===========================================================================
  // QR SCANNER PAYMENT
  // ===========================================================================

  Future<void> _openQrScanner() async {
    // Start discovery in background to resolve nearby endpoints if available
    final nearby = ref.read(nearbyServiceProvider);
    if (!_isDiscovering) {
      await nearby.startDiscovery(
        userName: _currentAccountName,
        onEndpointFound: (id, name) {
          final parts = name.split('|');
          if (mounted) {
            setState(() {
              _discoveredEndpoints[id] = parts[0];
              if (parts.length > 1) _endpointPublicKeys[id] = parts[1];
            });
          }
        },
        onEndpointLost: (id) {
          if (mounted) {
            setState(() {
              _discoveredEndpoints.remove(id);
              _endpointPublicKeys.remove(id);
            });
          }
        },
      );
      if (mounted) setState(() => _isDiscovering = true);
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => QrScannerScreen(
          title: 'Scan Merchant Payment QR',
          onScanned: (rawValue) {
            Navigator.pop(ctx);
            _handleQrScanned(rawValue);
          },
        ),
      ),
    );
  }

  void _handleQrScanned(String rawValue) {
    if (!mounted) return;
    String payeeName = 'Bole-Store';
    String payeePubkey = '';

    try {
      if (rawValue.startsWith('airbirr://pay')) {
        final uri = Uri.parse(rawValue);
        payeePubkey = uri.queryParameters['pubkey'] ?? '';
        payeeName = uri.queryParameters['name'] ?? 'Merchant';
      } else if (rawValue.startsWith('{') && rawValue.endsWith('}')) {
        final data = jsonDecode(rawValue) as Map<String, dynamic>;
        payeePubkey = data['public_key'] ?? data['pubkey'] ?? data['payee_pubkey'] ?? '';
        payeeName = data['merchant_name'] ?? data['name'] ?? data['payee'] ?? 'Merchant';
      } else {
        payeeName = rawValue.length > 16 ? rawValue.substring(0, 16) : rawValue;
      }
    } catch (_) {
      payeeName = 'Merchant';
    }

    // 1. RULE: Immediate self-payment rejection on QR parse
    if (payeePubkey.isNotEmpty && payeePubkey == _myPublicKeyBase64) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot pay yourself'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (payeeName.trim().toLowerCase() == _currentAccountName.trim().toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot send payment to yourself!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    _showPayDialog(
      payeeName: payeeName,
      payeePubkey: payeePubkey,
      isNearby: false,
    );
  }

  @visibleForTesting
  void handleQrScannedForTest(String rawValue) => _handleQrScanned(rawValue);

  // ===========================================================================
  // PAYMENT EXECUTION WITH 2-WAY ACK/NACK
  // ===========================================================================

  Future<void> _showPayDialog({
    required String payeeName,
    String? payeePubkey,
    String? endpointId,
    required bool isNearby,
  }) async {
    final amountController = TextEditingController(text: '50.0');
    bool simulateTamper = false;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Pay to $payeeName - Enter Amount (ETB)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Available Balance: ${_currentBalance.toStringAsFixed(2)} ETB',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('merchant_pay_amount_input'),
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
              const SizedBox(height: 14),
              // Developer Simulation Box
              Container(
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: CheckboxListTile(
                  key: const Key('simulate_tamper_checkbox'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  dense: true,
                  title: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'DEV TEST',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Simulate tampering (Corrupt Signature)',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  value: simulateTamper,
                  onChanged: (val) {
                    setDialogState(() {
                      simulateTamper = val ?? false;
                    });
                  },
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
              key: const Key('sign_and_pay_button'),
              onPressed: () {
                final parsed = double.tryParse(amountController.text.trim());
                if (parsed != null && parsed > 0) {
                  Navigator.pop(ctx, {
                    'amount': parsed,
                    'simulateTamper': simulateTamper,
                  });
                }
              },
              child: const Text('Sign & Pay'),
            ),
          ],
        ),
      ),
    );

    if (result != null && mounted) {
      final amount = result['amount'] as double;
      final tamper = result['simulateTamper'] as bool;
      await _executePayment(
        amount: amount,
        simulateTamper: tamper,
        payeeName: payeeName,
        payeePubkey: payeePubkey,
        endpointId: endpointId,
        isNearby: isNearby,
      );
    }
  }

  Future<void> _executePayment({
    required double amount,
    required bool simulateTamper,
    required String payeeName,
    String? payeePubkey,
    String? endpointId,
    required bool isNearby,
  }) async {
    if (_isSending) return; // Prevent double-tap race condition
    setState(() => _isSending = true);

    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(databaseServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    final nearby = ref.read(nearbyServiceProvider);

    // 1. RULE: Self-Payment Prevention
    if ((payeePubkey != null && payeePubkey.isNotEmpty && payeePubkey == _myPublicKeyBase64) ||
        payeeName.trim().toLowerCase() == _currentAccountName.trim().toLowerCase()) {
      if (mounted) setState(() => _isSending = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Cannot send payment to yourself!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // 2. Balance Check
    final amountCents = (amount * 100).round();
    final state = await db.getWalletState();
    final balanceCents = (state['offline_balance_cents'] as num? ?? 0).toInt();

    if (balanceCents < amountCents) {
      if (mounted) setState(() => _isSending = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Insufficient offline balance (${(balanceCents / 100.0).toStringAsFixed(2)} ETB available).',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    try {
      final myPubKeyBytes = await crypto.getPublicKeyRaw();
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final cleanPayeeId = payeeName.length > 16 ? payeeName.substring(0, 16) : payeeName;

      // Next expected nonce for this wallet
      final currentNonce = (state['current_nonce'] as num? ?? 0).toInt();
      final nextNonce = currentNonce + 1;

      final voucherId = DatabaseService.deriveVoucherId(
        payerPublicKey: myPubKeyBytes,
        nonce: nextNonce,
      );

      // Build VoucherPayload
      final payload = VoucherPayload(
        payerPublicKey: myPubKeyBytes,
        payeeId: cleanPayeeId,
        amountInCents: amountCents,
        nonce: nextNonce,
        timestampSeconds: nowSeconds,
      );

      // Deterministically sign voucher with Ed25519
      Uint8List signedBytes = await crypto.signVoucher(payload);

      // If simulate tampering is checked: corrupt the signature bytes
      if (simulateTamper) {
        final corrupted = Uint8List.fromList(signedBytes);
        for (int i = 60; i < corrupted.length; i++) {
          corrupted[i] = 0x00; // Zero out signature
        }
        signedBytes = corrupted;
      }

      final signatureBase64 = base64Encode(signedBytes.sublist(60));

      // Resolve destination endpointId for transmission
      final targetEndpoint = endpointId ??
          (_discoveredEndpoints.isNotEmpty ? _discoveredEndpoints.keys.first : 'target_merchant');

      // Transmit to merchant and await 2-way ACK/NACK
      final response = await nearby.sendVoucherAndWaitForResponse(
        endpointId: targetEndpoint,
        packedVoucherBytes: signedBytes,
        timeout: const Duration(seconds: 8),
      );

      if (response != null &&
          (response['type'] == 'ACK' || response['status'] == 'ACK' || response['status'] == 'CONFIRMED')) {
        // -------------------------------------------------------------
        // ON ACK: Debit balance and record SENT voucher in SQLite
        // -------------------------------------------------------------
        final deductOk = await db.deductBalanceAndIncrementNonce(amountCents);
        if (deductOk) {
          await db.recordSentVoucher(
            voucherId: voucherId,
            payerPubkey: _myPublicKeyBase64 ?? '',
            payeeId: cleanPayeeId,
            amount: amount,
            nonce: nextNonce,
            timestamp: nowSeconds,
            signature: signatureBase64,
            rawBytes: signedBytes,
          );

          // Tactile medium impact on confirmed payment receipt
          await HapticFeedback.mediumImpact();

          if (mounted) {
            setState(() {
              _successBanner = 'Payment of ${amount.toStringAsFixed(2)} ETB confirmed by $payeeName!';
            });
          }

          messenger.showSnackBar(
            SnackBar(
              content: Text('Payment of ${amount.toStringAsFixed(2)} ETB confirmed by $payeeName!'),
              backgroundColor: AppTheme.darkMintGreen,
              duration: const Duration(seconds: 4),
            ),
          );

          await _refreshWalletData();
          widget.onPaymentCompleted?.call();
        } else {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Error updating balance after ACK confirmation.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else if (response != null &&
          (response['type'] == 'NACK' || response['status'] == 'NACK' || response['status'] == 'REJECTED')) {
        // -------------------------------------------------------------
        // ON NACK: Debits 0 ETB, tactile vibrate, shows error banner
        // -------------------------------------------------------------
        await HapticFeedback.vibrate();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('[REJECTED] Merchant rejected voucher! No funds deducted.'),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        // -------------------------------------------------------------
        // ON TIMEOUT / NO ACK: Debits 0 ETB, shows error banner
        // -------------------------------------------------------------
        messenger.showSnackBar(
          const SnackBar(
            content: Text('[TIMEOUT] No response from merchant. Payment cancelled with 0 ETB deducted.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Payment transmission error: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final surfaceColor = AppColors.surface(context);
    final elevatedSurface = AppColors.surfaceElevated(context);
    final subtleBorder = AppColors.subtleBorder(context);
    final mintColor = AppColors.mint(context);
    final accentColor = AppTheme.accentColor(brightness);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Transaction Success Card with Tactile Motion (Curves.easeOutBack)
          if (_successBanner != null) ...[
            AnimatedScale(
              scale: 1.0,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: mintColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: mintColor, width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: mintColor.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: mintColor, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _successBanner!,
                        style: TextStyle(
                          color: mintColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: mintColor,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => setState(() => _successBanner = null),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Clean Segmented Pill Switch at Top ([QR Scan] | [Nearby BLE])
          Container(
            height: 48,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: elevatedSurface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: subtleBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() => _mode = SendMode.qr);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: _mode == SendMode.qr
                            ? (isDark ? accentColor.withValues(alpha: 0.18) : accentColor.withValues(alpha: 0.14))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: _mode == SendMode.qr
                            ? Border.all(color: accentColor.withValues(alpha: 0.5), width: 1.2)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.qr_code_scanner_rounded,
                            size: 18,
                            color: _mode == SendMode.qr ? accentColor : AppColors.textSecondary(context),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'QR Scan',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _mode == SendMode.qr ? FontWeight.bold : FontWeight.w500,
                              color: _mode == SendMode.qr ? accentColor : AppColors.textSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() => _mode = SendMode.nearby);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: _mode == SendMode.nearby
                            ? (isDark ? mintColor.withValues(alpha: 0.18) : mintColor.withValues(alpha: 0.14))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: _mode == SendMode.nearby
                            ? Border.all(color: mintColor.withValues(alpha: 0.5), width: 1.2)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bluetooth_searching_rounded,
                            size: 18,
                            color: _mode == SendMode.nearby ? mintColor : AppColors.textSecondary(context),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Nearby BLE',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _mode == SendMode.nearby ? FontWeight.bold : FontWeight.w500,
                              color: _mode == SendMode.nearby ? mintColor : AppColors.textSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // MODE 1: SCAN QR CODE
          if (_mode == SendMode.qr) ...[
            Container(
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: subtleBorder),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 30.0),
              child: Column(
                children: [
                  // Viewfinder Frame with Subtle Corner Scanner Overlays
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Soft glowing scanner container
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            color: accentColor.withValues(alpha: isDark ? 0.08 : 0.05),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.qr_code_scanner_rounded,
                              size: 56,
                              color: accentColor,
                            ),
                          ),
                        ),
                        // 4 Corner Brackets
                        Positioned(
                          top: 0,
                          left: 0,
                          child: _ViewfinderCorner(isTop: true, isLeft: true, color: accentColor),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: _ViewfinderCorner(isTop: true, isLeft: false, color: accentColor),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: _ViewfinderCorner(isTop: false, isLeft: true, color: accentColor),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: _ViewfinderCorner(isTop: false, isLeft: false, color: accentColor),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Scan Merchant Invoice',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Point camera at the merchant or friend\'s AirBirr QR code to pay instantly.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary(context),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('scan_merchant_qr_button'),
                    onPressed: _isSending ? null : _openQrScanner,
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: const Text('Scan Merchant QR to Pay'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // MODE 2: SEARCH NEARBY PHONES (BLE NEARBY)
          if (_mode == SendMode.nearby) ...[
            Container(
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: subtleBorder),
              ),
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      // Pulsing radar icon
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (_isDiscovering)
                              AnimatedBuilder(
                                animation: _radarAnimation,
                                builder: (context, child) {
                                  final scale = 1.0 + (_radarAnimation.value * 0.38);
                                  final alpha = (1.0 - _radarAnimation.value) * 0.45;
                                  return Container(
                                    width: 36 * scale,
                                    height: 36 * scale,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: mintColor.withValues(alpha: alpha),
                                        width: 1.8,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isDiscovering
                                    ? mintColor.withValues(alpha: 0.15)
                                    : elevatedSurface,
                                border: Border.all(
                                  color: _isDiscovering ? mintColor : subtleBorder,
                                ),
                              ),
                              child: Icon(
                                _isDiscovering ? Icons.radar_rounded : Icons.bluetooth_searching_rounded,
                                color: _isDiscovering ? mintColor : AppColors.textSecondary(context),
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Nearby Merchant Phones',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _isDiscovering
                                  ? 'Scanning for broadcast beacons...'
                                  : 'Discover recipients over Bluetooth BLE',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isDiscovering)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    key: const Key('toggle_discovery_button'),
                    onPressed: _toggleDiscovery,
                    icon: Icon(_isDiscovering ? Icons.stop_rounded : Icons.radar_rounded),
                    label: Text(_isDiscovering ? 'Stop Scanning' : 'Search Nearby Phones'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Discovered Endpoints List
            if (_discoveredEndpoints.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36.0),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        _isDiscovering ? Icons.wifi_tethering_rounded : Icons.cell_tower_rounded,
                        size: 48,
                        color: AppColors.textTertiary(context),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isDiscovering
                            ? 'Searching for nearby phones broadcasting beacons...'
                            : 'Tap "Search Nearby Phones" to find recipients.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _discoveredEndpoints.length,
                itemBuilder: (ctx, index) {
                  final endpointId = _discoveredEndpoints.keys.elementAt(index);
                  final endpointName = _discoveredEndpoints[endpointId]!;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: subtleBorder),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: accentColor.withValues(alpha: 0.15),
                        child: Icon(Icons.phone_android_rounded, color: accentColor, size: 20),
                      ),
                      title: Text(
                        endpointName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      subtitle: Row(
                        children: [
                          Icon(
                            Icons.bluetooth_connected_rounded,
                            size: 13,
                            color: mintColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Nearby Peer • ID: $endpointId',
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppColors.textSecondary(context),
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      trailing: FilledButton(
                        onPressed: _isSending
                            ? null
                            : () => _showPayDialog(
                                  payeeName: endpointName,
                                  endpointId: endpointId,
                                  isNearby: true,
                                ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Pay'),
                      ),
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

/// Viewfinder corner scanner overlay bracket for camera frame.
class _ViewfinderCorner extends StatelessWidget {
  final bool isTop;
  final bool isLeft;
  final Color color;

  const _ViewfinderCorner({
    required this.isTop,
    required this.isLeft,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    const size = 22.0;
    const stroke = 3.0;
    const radius = 6.0;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border(
          top: isTop ? BorderSide(color: color, width: stroke) : BorderSide.none,
          bottom: !isTop ? BorderSide(color: color, width: stroke) : BorderSide.none,
          left: isLeft ? BorderSide(color: color, width: stroke) : BorderSide.none,
          right: !isLeft ? BorderSide(color: color, width: stroke) : BorderSide.none,
        ),
        borderRadius: BorderRadius.only(
          topLeft: isTop && isLeft ? const Radius.circular(radius) : Radius.zero,
          topRight: isTop && !isLeft ? const Radius.circular(radius) : Radius.zero,
          bottomLeft: !isTop && isLeft ? const Radius.circular(radius) : Radius.zero,
          bottomRight: !isTop && !isLeft ? const Radius.circular(radius) : Radius.zero,
        ),
      ),
    );
  }
}

/// Backward compatibility alias for SendScreen.
typedef SendScreen = SendTab;
