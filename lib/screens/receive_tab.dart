import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/crypto_service.dart';
import '../services/database_service.dart';
import '../services/nearby_service.dart';
import '../theme/app_theme.dart';

enum ReceiveStatus { idle, advertising, processing }

/// Receive Tab displaying personal Receive QR Code and BLE Nearby advertising beacon.
///
/// When payment arrives over BLE:
/// - Verifies Ed25519 cryptographic signature mathematically (Rule 3).
/// - Inserts into SQLite append-only ledger with type = 'RECEIVED'.
/// - Credits local vault balance and responds with an ACK payload.
/// - Triggers haptic feedback.
class ReceiveTab extends ConsumerStatefulWidget {
  final Map<String, dynamic> profile;
  final VoidCallback? onPaymentReceived;

  const ReceiveTab({
    super.key,
    required this.profile,
    this.onPaymentReceived,
  });

  @override
  ConsumerState<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends ConsumerState<ReceiveTab> with SingleTickerProviderStateMixin {
  bool _isAdvertising = false;
  ReceiveStatus _status = ReceiveStatus.idle;
  String? _successBanner;
  String? _alertBanner;
  String? _publicKeyBase64;
  double _balance = 0.0;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  String get _displayName =>
      widget.profile['display_name']?.toString() ??
      widget.profile['account_id']?.toString() ??
      'AirBirr-User';

  String get _qrPayload {
    final pubKey = _publicKeyBase64 ?? '';
    return jsonEncode({
      'type': 'RECEIVE_REQUEST',
      'payee': _displayName,
      'pubkey': pubKey,
    });
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadState();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    try {
      ref.read(nearbyServiceProvider).stopAll();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadState() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final crypto = ref.read(cryptoServiceProvider);

      final state = await db.getWalletState();
      final pubKey = await crypto.getPublicKeyBase64();

      if (mounted) {
        setState(() {
          _balance = (state['offline_balance_cents'] as num? ?? 0) / 100.0;
          _publicKeyBase64 = pubKey;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleAdvertising() async {
    final nearby = ref.read(nearbyServiceProvider);
    await HapticFeedback.lightImpact();

    if (_isAdvertising) {
      await nearby.stopAdvertising();
      _pulseController.stop();
      _pulseController.reset();
      if (mounted) {
        setState(() {
          _isAdvertising = false;
          _status = ReceiveStatus.idle;
        });
      }
    } else {
      setState(() {
        _status = ReceiveStatus.advertising;
      });

      // Broadcast format: "DisplayName|PublicKey"
      final advertisedName = '$_displayName|${_publicKeyBase64 ?? ''}';

      final success = await nearby.startAdvertising(
        merchantName: advertisedName,
        onPayloadReceived: (endpointId, rawBytes) {
          _handleIncomingVoucher(endpointId, rawBytes);
        },
      );

      if (mounted) {
        if (success) {
          _pulseController.repeat(reverse: true);
        } else {
          _pulseController.stop();
          _pulseController.reset();
        }
        setState(() {
          _isAdvertising = success;
          _status = success ? ReceiveStatus.advertising : ReceiveStatus.idle;
        });
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to start BLE Beacon. Check Bluetooth permissions.')),
          );
        }
      }
    }
  }

  Future<void> _handleIncomingVoucher(String endpointId, Uint8List rawBytes) async {
    setState(() {
      _status = ReceiveStatus.processing;
    });

    final crypto = ref.read(cryptoServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final nearby = ref.read(nearbyServiceProvider);

    try {
      Map<String, dynamic> json;
      Uint8List? rawVoucherBytes;

      try {
        final str = utf8.decode(rawBytes);
        json = jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        if (rawBytes.length == 124) {
          final (p, sig) = CryptoService.unpackFullVoucher(rawBytes);
          rawVoucherBytes = rawBytes;
          json = {
            'voucher_id': DatabaseService.deriveVoucherId(
              payerPublicKey: p.payerPublicKey,
              nonce: p.nonce,
            ),
            'payer': base64Encode(p.payerPublicKey),
            'payee': p.payeeId,
            'amount': p.amountInCents / 100.0,
            'nonce': p.nonce,
            'timestamp': p.timestampSeconds,
            'signature': base64Encode(sig),
          };
        } else {
          throw const FormatException('Unrecognized voucher payload');
        }
      }

      final voucherId = (json['voucher_id'] ?? json['id'])?.toString() ?? '';
      final signature = json['signature']?.toString() ?? '';
      final payerPubkey = (json['payer'] ?? json['payer_pubkey'])?.toString() ?? '';
      final payeeId = (json['payee'] ?? json['payee_id'])?.toString() ?? _displayName;
      final nonce = (json['nonce'] as num?)?.toInt() ?? 0;
      final timestamp = (json['timestamp'] as num?)?.toInt() ?? 0;
      final double amount = (json['amount'] as num?)?.toDouble() ??
          (((json['amount_cents'] as num?)?.toDouble() ?? 0.0) / 100.0);

      // 1. Check for duplicate voucher in SQLite (Idempotent replay prevention)
      if (voucherId.isNotEmpty) {
        final dbInstance = await db.database;
        final existing = await dbInstance.query(
          'vouchers',
          columns: ['voucher_id'],
          where: 'voucher_id = ?',
          whereArgs: [voucherId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final ackPayload = jsonEncode({
            'type': 'ACK',
            'status': 'CONFIRMED',
            'voucher_id': voucherId,
            'note': 'Already recorded (idempotent duplicate)',
          });
          await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(ackPayload)));
          if (mounted) {
            setState(() {
              _successBanner = 'Recognized duplicate voucher (${amount.toStringAsFixed(2)} ETB)';
              _status = _isAdvertising ? ReceiveStatus.advertising : ReceiveStatus.idle;
            });
          }
          return;
        }
      }

      // 2. Reject self-payment
      final myKey = _publicKeyBase64 ?? await crypto.getPublicKeyBase64();
      if (payerPubkey.isNotEmpty && payerPubkey == myKey) {
        final nackPayload = jsonEncode({
          'type': 'NACK',
          'voucher_id': voucherId,
          'status': 'REJECTED',
          'reason': 'Cannot accept self-payment',
        });
        await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(nackPayload)));
        await HapticFeedback.vibrate();
        if (mounted) {
          setState(() {
            _alertBanner = '[ALERT] Rejected self-payment attempt.';
            _status = _isAdvertising ? ReceiveStatus.advertising : ReceiveStatus.idle;
          });
        }
        return;
      }

      // 3. Mathematical signature verification (Rule 3)
      bool isValid = false;
      if (rawVoucherBytes != null && rawVoucherBytes.length == 124) {
        isValid = await crypto.verifyVoucher(rawVoucherBytes);
      } else if (signature.isNotEmpty && payerPubkey.isNotEmpty) {
        final payloadToVerify = Map<String, dynamic>.from(json)..remove('signature');
        isValid = await crypto.verifySignature(
          payload: payloadToVerify,
          signatureBase64: signature,
          publicKeyBase64: payerPubkey,
        );
      }

      if (isValid) {
        // Record RECEIVED voucher in SQLite
        await db.recordReceivedVoucher(
          voucherId: voucherId,
          payerPubkey: payerPubkey,
          payeeId: payeeId,
          amount: amount,
          nonce: nonce,
          timestamp: timestamp,
          signature: signature,
          rawBytes: rawVoucherBytes,
        );

        // Credit local balance
        final currentBal = await db.getWalletBalance();
        await db.updateWalletBalance(currentBal + amount);

        // Trigger haptic vibration
        await HapticFeedback.mediumImpact();

        // Send ACK back to sender
        final ackPayload = jsonEncode({
          'type': 'ACK',
          'status': 'CONFIRMED',
          'voucher_id': voucherId,
          'amount': amount,
          'payee': _displayName,
        });
        await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(ackPayload)));

        if (mounted) {
          setState(() {
            _successBanner = '[RECEIVED] +${amount.toStringAsFixed(2)} ETB from payer!';
            _alertBanner = null;
            _status = _isAdvertising ? ReceiveStatus.advertising : ReceiveStatus.idle;
          });
        }

        await _loadState();
        widget.onPaymentReceived?.call();
      } else {
        // Tampered or invalid voucher: send NACK and tactile vibrate
        final nackPayload = jsonEncode({
          'type': 'NACK',
          'status': 'REJECTED',
          'voucher_id': voucherId,
          'reason': 'Invalid Signature',
        });
        await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(nackPayload)));
        await HapticFeedback.vibrate();

        if (mounted) {
          setState(() {
            _alertBanner = '[ALERT] Rejected invalid/tampered voucher!';
            _status = _isAdvertising ? ReceiveStatus.advertising : ReceiveStatus.idle;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _alertBanner = 'Error processing incoming voucher: $e';
          _status = _isAdvertising ? ReceiveStatus.advertising : ReceiveStatus.idle;
        });
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
    final errorColor = AppColors.sent(context);

    final normalizedAccountId = widget.profile['account_id']?.toString() ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Success / Alert Banners with Tactile Motion (Curves.easeOutBack)
          if (_successBanner != null) ...[
            AnimatedScale(
              scale: 1.0,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            const SizedBox(height: 14),
          ],
          if (_alertBanner != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: errorColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: errorColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: errorColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _alertBanner!,
                      style: TextStyle(color: errorColor, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: errorColor,
                    onPressed: () => setState(() => _alertBanner = null),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // Ticket-Style Centered White QR Card (with quiet-zone padding & user identity pill)
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE2E8F0),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark ? Colors.black.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                // Ticket Header: User Name + Normalized Phone Pill
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF262626) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark ? const Color(0xFF383838) : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: mintColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _displayName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isDark ? Colors.white : const Color(0xFF0F172A),
                              ),
                            ),
                            if (normalizedAccountId.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(
                                '• $normalizedAccountId',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? Colors.white70 : const Color(0xFF64748B),
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Scan with any AirBirr app to send offline payment',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),

                // High-Contrast White QR Card with Quiet-Zone Padding
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Container(
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      key: const Key('receive_qr_code'),
                      data: _qrPayload,
                      version: QrVersions.auto,
                      size: 200.0,
                      backgroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // Perforated Ticket Divider
                Row(
                  children: [
                    Container(
                      width: 14,
                      height: 24,
                      decoration: BoxDecoration(
                        color: theme.scaffoldBackgroundColor,
                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                        border: Border.all(
                          color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final dashCount = (constraints.constrainWidth() / 10).floor();
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: List.generate(
                              dashCount,
                              (_) => SizedBox(
                                width: 5,
                                height: 1.5,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF383838) : const Color(0xFFCBD5E1),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Container(
                      width: 14,
                      height: 24,
                      decoration: BoxDecoration(
                        color: theme.scaffoldBackgroundColor,
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                        border: Border.all(
                          color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ],
                ),

                // Ticket Footer: Vault Balance Readout
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Vault Balance: ',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                      Text(
                        '${_balance.toStringAsFixed(2)} ETB',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: mintColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // BLE Beacon Card with Animated Pulsing Ring
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
                    // Animated Pulsing Ring around Bluetooth Icon
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (_isAdvertising)
                            AnimatedBuilder(
                              animation: _pulseAnimation,
                              builder: (context, child) {
                                final scale = 1.0 + (_pulseAnimation.value * 0.38);
                                final alpha = (1.0 - _pulseAnimation.value) * 0.45;
                                return Container(
                                  width: 38 * scale,
                                  height: 38 * scale,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: mintColor.withValues(alpha: alpha),
                                      width: 2.0,
                                    ),
                                    color: mintColor.withValues(alpha: alpha * 0.22),
                                  ),
                                );
                              },
                            ),
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isAdvertising
                                  ? mintColor.withValues(alpha: 0.16)
                                  : elevatedSurface,
                              border: Border.all(
                                color: _isAdvertising ? mintColor : subtleBorder,
                                width: 1.2,
                              ),
                            ),
                            child: Icon(
                              _isAdvertising ? Icons.bluetooth_audio_rounded : Icons.bluetooth_disabled_rounded,
                              color: _isAdvertising ? mintColor : AppColors.textSecondary(context),
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
                            _isAdvertising ? 'Beacon Active (Listening...)' : 'Beacon Idle',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: _isAdvertising ? mintColor : AppColors.textPrimary(context),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isAdvertising
                                ? 'Nearby phones can discover and pay you directly'
                                : 'Broadcast Bluetooth beacon for nearby payers',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_status == ReceiveStatus.processing)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                FilledButton.tonal(
                  key: const Key('toggle_beacon_button'),
                  onPressed: _toggleAdvertising,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(_isAdvertising ? 'Stop Beacon' : 'Broadcast Bluetooth Beacon'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Physical Proximity & Offline Guidance Helper
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: elevatedSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: subtleBorder),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: AppColors.textSecondary(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offline P2P operates via local BLE & QR. Keep phones within 2–5m with Bluetooth enabled. No internet required.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary(context),
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Backward compatibility alias for ReceiveScreen.
typedef ReceiveScreen = ReceiveTab;
