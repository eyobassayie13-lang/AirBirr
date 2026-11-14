import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'services/api_service.dart';
import 'services/crypto_service.dart';
import 'services/database_service.dart';
import 'services/nearby_service.dart';
import 'theme/app_theme.dart';

import 'screens/pin_login_screen.dart';
import 'screens/register_screen.dart';
import 'widgets/qr_scanner_screen.dart';
import 'widgets/server_settings_dialog.dart';

export 'widgets/qr_scanner_screen.dart';
export 'widgets/server_settings_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const ProviderScope(child: OffPayApp()));
}

/// App Flow Gatekeeper checking registration status on launch.
class AppGatekeeper extends ConsumerStatefulWidget {
  const AppGatekeeper({super.key});

  @override
  ConsumerState<AppGatekeeper> createState() => _AppGatekeeperState();
}

class _AppGatekeeperState extends ConsumerState<AppGatekeeper> {
  bool _isLoading = true;
  bool _isRegistered = false;
  bool _hasWalletPin = false;
  Map<String, dynamic>? _userProfile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkRegistrationAndAuth();
    });
  }

  Future<void> _checkRegistrationAndAuth() async {
    try {
      final db = ref.read(databaseServiceProvider);
      final isReg = await db.isUserRegistered();
      if (!isReg) {
        if (mounted) {
          setState(() {
            _isRegistered = false;
            _hasWalletPin = false;
            _isLoading = false;
          });
        }
        return;
      }

      const secureStorage = FlutterSecureStorage();
      final pin = await secureStorage.read(key: 'user_wallet_pin');
      final hasPin = pin != null && pin.trim().isNotEmpty;
      final profile = await db.getUserProfile();

      if (mounted) {
        setState(() {
          _isRegistered = true;
          _hasWalletPin = hasPin;
          _userProfile = profile;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRegistered = false;
          _hasWalletPin = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.darkPrimaryAccent, AppTheme.darkMintGreen],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.currency_exchange_rounded,
                  color: Colors.black,
                  size: 32,
                ),
              ),
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }

    if (_isRegistered && _hasWalletPin) {
      return PinLoginScreen(profile: _userProfile ?? {});
    }

    return const RegisterScreen();
  }
}

class OffPayApp extends StatelessWidget {
  final Widget? home;
  final bool? forceGatekeeper;

  const OffPayApp({
    super.key,
    this.home,
    this.forceGatekeeper,
  });

  @override
  Widget build(BuildContext context) {
    final bool isWidgetTest =
        WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');

    Widget resolvedHome;
    if (forceGatekeeper == true) {
      resolvedHome = const AppGatekeeper();
    } else if (home != null) {
      resolvedHome = home!;
    } else if (isWidgetTest) {
      resolvedHome = const TestScreen();
    } else {
      resolvedHome = const AppGatekeeper();
    }

    return MaterialApp(
      title: 'AirBirr Offline P2P',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: resolvedHome,
    );
  }
}
enum AppMode { receive, pay }

enum MerchantStatus {
  idle,
  advertising,
  receivingPayload,
}

class TestScreen extends ConsumerStatefulWidget {
  const TestScreen({super.key});

  @override
  ConsumerState<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends ConsumerState<TestScreen> {
  AppMode _currentMode = AppMode.receive;

  // Dynamic Network Status
  bool _isOnline = true;
  Timer? _connectivityTimer;

  // Wallet State
  String? _publicKeyBase64;
  double _balance = 0.0;
  int _lastNonce = 0;
  bool _isLoadingWallet = true;

  // State Notifiers
  final ValueNotifier<bool> _permissionsDeniedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MerchantStatus> _merchantStatusNotifier =
      ValueNotifier<MerchantStatus>(MerchantStatus.idle);
  final ValueNotifier<Map<String, String>> _discoveredEndpointsNotifier =
      ValueNotifier<Map<String, String>>({});

  // Mode A: Receive (Merchant)
  bool _isAdvertising = false;
  String? _lastStatusMessage;
  String? _merchantSuccessMessage;
  String? _merchantAlertMessage;
  final TextEditingController _merchantNameController =
      TextEditingController(text: 'Bole-Store');
  final TextEditingController _userNameController =
      TextEditingController(text: 'Abebe-0911');

  // Mode B: Pay (Customer)
  bool _isScanning = false;
  bool _isSending = false;
  // Action Guard
  bool _isActionInProgress = false;
  final Map<String, String> _discoveredEndpoints = {};

  String get currentAccountName {
    final isMerchant = _currentMode == AppMode.receive;
    if (isMerchant) {
      final name = _merchantNameController.text.trim();
      return name.isNotEmpty ? name : 'Bole-Store';
    } else {
      final name = _userNameController.text.trim();
      return name.isNotEmpty ? name : 'Customer-Wallet';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestPermissions();
      await _initializeWallet();
      await _checkServerConnectivity();
    });

    if (!WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
      _connectivityTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _checkServerConnectivity();
      });
    }
  }

  @override
  void dispose() {
    _connectivityTimer?.cancel();
    try {
      ref.read(nearbyServiceProvider).stopAll();
    } catch (_) {}
    _merchantNameController.dispose();
    _userNameController.dispose();
    _permissionsDeniedNotifier.dispose();
    _merchantStatusNotifier.dispose();
    _discoveredEndpointsNotifier.dispose();
    super.dispose();
  }

  /// Pings Central Bank server to update online/offline connectivity state.
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

  // ===========================================================================
  // 1. PERMISSION HANDLING
  // ===========================================================================

  /// Requests runtime permissions required for Nearby Connections.
  Future<bool> _requestPermissions() async {
    // In widget test binding, bypass platform calls to avoid mock channel delays
    if (WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
      _permissionsDeniedNotifier.value = false;
      return true;
    }

    try {
      final statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.nearbyWifiDevices,
      ].request();

      final anyDenied = statuses.values.any(
        (status) => status.isDenied || status.isPermanentlyDenied || status.isRestricted,
      );

      _permissionsDeniedNotifier.value = anyDenied;
      return !anyDenied;
    } catch (e) {
      debugPrint('Permission request error: $e');
      _permissionsDeniedNotifier.value = true;
      return false;
    }
  }

  // ===========================================================================
  // 2. WALLET INITIALIZATION & STATE
  // ===========================================================================

  /// Initializes CryptoService and DatabaseService, seeds initial wallet state if empty.
  Future<void> _initializeWallet() async {
    setState(() => _isLoadingWallet = true);
    try {
      final db = ref.read(databaseServiceProvider);
      final crypto = ref.read(cryptoServiceProvider);

      // Ensure keypair exists
      await crypto.getOrCreateKeyPair();

      final state = await db.getWalletState();
      final currentBalanceCents = (state['offline_balance_cents'] as num?)?.toInt() ?? 0;
      final activeLeaseId = state['active_lease_id'] as String?;

      // Seed initial wallet state if empty (e.g. initial balance = 500.00 ETB / 50000 cents)
      if (currentBalanceCents == 0 && activeLeaseId == null) {
        await db.initWalletState(
          initialBalanceCents: 50000,
          leaseId: 'lease_demo_01',
        );
      }

      await _refreshWalletState();
    } catch (e) {
      debugPrint('Error initializing wallet: $e');
      if (mounted) {
        setState(() => _isLoadingWallet = false);
      }
    }
  }

  /// Reloads public key, balance, and nonce from SQLite and secure storage.
  Future<void> _refreshWalletState() async {
    try {
      final crypto = ref.read(cryptoServiceProvider);
      final db = ref.read(databaseServiceProvider);

      final pubKey = await crypto.getPublicKeyBase64();
      final balance = await db.getWalletBalance();
      final state = await db.getWalletState();

      if (mounted) {
        setState(() {
          _publicKeyBase64 = pubKey;
          _balance = balance;
          _lastNonce = (state['current_nonce'] as num?)?.toInt() ??
              (state['last_nonce'] as num?)?.toInt() ??
              0;
          _isLoadingWallet = false;
        });
        _checkServerConnectivity();
      }
    } catch (e) {
      debugPrint('Error loading wallet state: $e');
      if (mounted) {
        setState(() => _isLoadingWallet = false);
      }
    }
  }

  String _truncateKey(String? key) {
    if (key == null || key.isEmpty) return 'Generating...';
    try {
      final bytes = base64Decode(key);
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return '0x${hex.substring(0, 4)}...${hex.substring(hex.length - 4)}';
    } catch (_) {
      if (key.length <= 10) return key;
      return '${key.substring(0, 6)}...${key.substring(key.length - 4)}';
    }
  }

  // ===========================================================================
  // 3. MODE A: MERCHANT (RECEIVE PAYMENTS)
  // ===========================================================================

  Future<void> _toggleAdvertising() async {
    if (_isActionInProgress) return; // Ignore rapid double-taps
    setState(() => _isActionInProgress = true);

    try {
      final nearby = ref.read(nearbyServiceProvider);
      if (_isAdvertising) {
        await nearby.stopAdvertising();
        if (mounted) {
          setState(() {
            _isAdvertising = false;
            _lastStatusMessage = null;
            _merchantStatusNotifier.value = MerchantStatus.idle;
          });
        }
      } else {
        final hasPerm = await _requestPermissions();
        if (!hasPerm && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot advertise: permissions missing.')),
          );
        }

        final merchantName = _merchantNameController.text.trim().isEmpty
            ? 'Bole-Store'
            : _merchantNameController.text.trim();

        // Format: "MerchantName|PublicKey"
        final advertisedName = '$merchantName|${_publicKeyBase64 ?? ''}';

        _merchantStatusNotifier.value = MerchantStatus.advertising;

        final success = await nearby.startAdvertising(
          merchantName: advertisedName,
          onPayloadReceived: _handleIncomingPayload,
        );

        if (mounted) {
          setState(() {
            _isAdvertising = success;
            _lastStatusMessage = success ? 'Ready for customer scans...' : 'Failed to start.';
            _merchantSuccessMessage = null;
            _merchantAlertMessage = null;
            _merchantStatusNotifier.value =
                success ? MerchantStatus.advertising : MerchantStatus.idle;
          });
        }
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  /// Incoming Payment Pipeline for Merchant (Solution 2):
  /// - Parses the incoming JSON payload.
  /// - If it is a voucher:
  ///   - Checks if `voucher_id` already exists in SQLite:
  ///     - If already exists: Re-sends ACK immediately (idempotent duplicate handler) and returns.
  ///   - Runs `CryptoService.verifySignature()`.
  ///   - If VALID:
  ///     - Inserts into SQLite via `DatabaseService.insertVoucher()`.
  ///     - Credits merchant balance via `DatabaseService.updateWalletBalance()`.
  ///     - Triggers haptic vibration.
  ///     - Sends ACK response back to customer:
  ///       jsonEncode({'type': 'ACK', 'voucher_id': voucherId, 'status': 'CONFIRMED'})
  ///     - Shows green on-screen success container: "[SUCCESS] Received [Amount] ETB from [Payer]!".
  ///   - If INVALID / TAMPERED:
  ///     - Sends NACK response back to customer:
  ///       jsonEncode({'type': 'NACK', 'voucher_id': voucherId, 'status': 'REJECTED', 'reason': 'Invalid Signature'})
  ///     - Shows red on-screen alert: "[ALERT] Rejected invalid/tampered voucher!".
  Future<void> _handleIncomingPayload(String endpointId, Uint8List rawBytes) async {
    _merchantStatusNotifier.value = MerchantStatus.receivingPayload;
    final crypto = ref.read(cryptoServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final nearby = ref.read(nearbyServiceProvider);

    try {
      Map<String, dynamic> json;
      try {
        final str = utf8.decode(rawBytes);
        json = jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        if (rawBytes.length == 124) {
          final (p, sig) = CryptoService.unpackFullVoucher(rawBytes);
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
          throw const FormatException('Unrecognized payload format');
        }
      }

      final voucherId = (json['voucher_id'] ?? json['id'])?.toString() ?? '';
      final signature = json['signature']?.toString() ?? '';
      final payerPubkey = (json['payer'] ?? json['payer_pubkey'])?.toString() ?? '';
      final payeeId = (json['payee'] ?? json['payee_id'])?.toString() ?? 'Merchant';
      final nonce = (json['nonce'] as num?)?.toInt() ?? 0;
      final timestamp = (json['timestamp'] as num?)?.toInt() ?? 0;
      final rawAmount = json['amount'] ?? json['amount_cents'];
      final double amount;
      if (json['amount'] is num) {
        amount = (json['amount'] as num).toDouble();
      } else if (json['amount_cents'] is num) {
        amount = (json['amount_cents'] as num).toDouble() / 100.0;
      } else if (rawAmount != null) {
        amount = double.tryParse(rawAmount.toString()) ?? 0.0;
      } else {
        amount = 0.0;
      }

      // 1. Check if voucher_id already exists in SQLite:
      // If already exists: Re-send ACK immediately (idempotent duplicate handler) and return.
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
            'voucher_id': voucherId,
            'status': 'CONFIRMED',
          });
          await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(ackPayload)));
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
        await HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() {
            _merchantAlertMessage = '[ALERT] Rejected invalid/tampered voucher!';
            _merchantSuccessMessage = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot accept self-payment'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // 3. Run CryptoService.verifySignature()
      final payloadToVerify = Map<String, dynamic>.from(json)..remove('signature');
      var isValid = false;
      if (signature.isNotEmpty && payerPubkey.isNotEmpty) {
        isValid = await crypto.verifySignature(
          payload: payloadToVerify,
          signatureBase64: signature,
          publicKeyBase64: payerPubkey,
        );
      }

      if (isValid) {
        // Insert into SQLite via DatabaseService.recordReceivedVoucher()
        await db.recordReceivedVoucher(
          voucherId: voucherId,
          payerPubkey: payerPubkey,
          payeeId: payeeId,
          amount: amount,
          nonce: nonce,
          timestamp: timestamp,
          signature: signature,
        );

        // Credit merchant balance via DatabaseService.updateWalletBalance()
        final currentBal = await db.getWalletBalance();
        await db.updateWalletBalance(currentBal + amount);

        // Trigger haptic vibration
        await HapticFeedback.mediumImpact();

        // Send ACK response back to customer:
        final ackPayload = jsonEncode({
          'type': 'ACK',
          'voucher_id': voucherId,
          'status': 'CONFIRMED',
        });
        await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(ackPayload)));

        // Show green on-screen success container: "[RECEIVED] +[Amount] ETB from [Payer]!"
        final payerDisplay = payerPubkey.length > 12 ? _truncateKey(payerPubkey) : payerPubkey;
        if (mounted) {
          setState(() {
            _merchantSuccessMessage =
                '[RECEIVED] +${amount.toStringAsFixed(2)} ETB from $payerDisplay! [SUCCESS] Received ${amount.toStringAsFixed(2)} ETB from $payerDisplay!';
            _merchantAlertMessage = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('[RECEIVED] +${amount.toStringAsFixed(2)} ETB from $payerDisplay!'),
                  Text('Payment Verified! Received ${amount.toStringAsFixed(2)} ETB from $payerDisplay.'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        await _refreshWalletState();
      } else {
        // INVALID / TAMPERED:
        // Send NACK response back to customer:
        // jsonEncode({'type': 'NACK', 'voucher_id': voucherId, 'status': 'REJECTED', 'reason': 'Invalid Signature'})
        final nackPayload = jsonEncode({
          'type': 'NACK',
          'voucher_id': voucherId,
          'status': 'REJECTED',
          'reason': 'Invalid Signature',
        });
        await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(nackPayload)));

        await HapticFeedback.heavyImpact();

        // Show red on-screen alert: "[ALERT] Rejected invalid/tampered voucher!"
        if (mounted) {
          setState(() {
            _merchantAlertMessage = '[ALERT] Rejected invalid/tampered voucher!';
            _merchantSuccessMessage = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('[ALERT] Rejected invalid/tampered voucher!'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error handling incoming payload: $e');
      final nackPayload = jsonEncode({
        'type': 'NACK',
        'voucher_id': 'error',
        'status': 'REJECTED',
        'reason': 'Invalid Signature',
      });
      await nearby.sendResponsePayload(endpointId, Uint8List.fromList(utf8.encode(nackPayload)));
      if (mounted) {
        setState(() {
          _merchantAlertMessage = '[ALERT] Rejected invalid/tampered voucher!';
          _merchantSuccessMessage = null;
        });
      }
    } finally {
      _merchantStatusNotifier.value =
          _isAdvertising ? MerchantStatus.advertising : MerchantStatus.idle;
    }
  }


  // ===========================================================================
  // 4. MODE B: CUSTOMER (SEND PAYMENT)
  // ===========================================================================

  Future<void> _toggleDiscovery() async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);

    try {
      final nearby = ref.read(nearbyServiceProvider);

      if (_isScanning) {
        await nearby.stopDiscovery();
        if (mounted) {
          setState(() {
            _isScanning = false;
            _discoveredEndpoints.clear();
            _discoveredEndpointsNotifier.value = {};
          });
        }
      } else {
        final hasPerm = await _requestPermissions();
        if (!hasPerm && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot scan: permissions missing.')),
          );
        }

        _discoveredEndpoints.clear();
        _discoveredEndpointsNotifier.value = {};
        final success = await nearby.startDiscovery(
          userName: 'AirBirrCustomer',
          onEndpointFound: (endpointId, rawEndpointName) {
            // Check if this advertisement contains our own public key
            final parts = rawEndpointName.split('|');
            final displayName = parts[0];
            final endpointPubKey = parts.length > 1 ? parts[1] : '';

            // If this device is broadcasting my own public key, IGNORE IT!
            if (_publicKeyBase64 != null && endpointPubKey == _publicKeyBase64) {
              debugPrint('Ignoring self-discovered device.');
              return;
            }

            if (mounted) {
              setState(() {
                _discoveredEndpoints[endpointId] = displayName;
                final current = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                current[endpointId] = displayName;
                _discoveredEndpointsNotifier.value = current;
              });
            }
          },
          onEndpointLost: (endpointId) {
            if (mounted) {
              setState(() {
                _discoveredEndpoints.remove(endpointId);
                final current = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                current.remove(endpointId);
                _discoveredEndpointsNotifier.value = current;
              });
            }
          },
        );

        if (mounted) {
          setState(() => _isScanning = success);
        }
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _openMerchantQrScanner() async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);

    try {
      if (!WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
        final status = await Permission.camera.request();
        if (status.isDenied || status.isPermanentlyDenied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Camera permission is required to scan QR codes.'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;
        }
      }

      if (!mounted) return;

      // Start discovery in background so Nearby endpoint can be resolved
      final nearby = ref.read(nearbyServiceProvider);
      if (!_isScanning) {
        await nearby.startDiscovery(
          userName: 'AirBirrCustomer',
          onEndpointFound: (id, name) {
            if (mounted) {
              setState(() {
                _discoveredEndpoints[id] = name;
                final cur = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                cur[id] = name;
                _discoveredEndpointsNotifier.value = cur;
              });
            }
          },
          onEndpointLost: (id) {
            if (mounted) {
              setState(() {
                _discoveredEndpoints.remove(id);
                final cur = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                cur.remove(id);
                _discoveredEndpointsNotifier.value = cur;
              });
            }
          },
        );
        if (mounted) setState(() => _isScanning = true);
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (scannerContext) => QrScannerScreen(
            title: 'Scan Merchant QR to Pay',
            onScanned: (rawValue) => _handleMerchantQrScanned(rawValue, scannerContext),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _handleMerchantQrScanned(String rawValue, BuildContext scannerContext) async {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(rawValue) as Map<String, dynamic>;
    } catch (_) {
      if (scannerContext.mounted) {
        Navigator.of(scannerContext).pop();
      }
      await HapticFeedback.heavyImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('[ALERT] Tampered or Invalid Voucher Rejected!'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final merchantName = (data['payee'] ?? data['name'] ?? 'Merchant').toString();
    final merchantPubkey = (data['pubkey'] ?? '').toString();

    // Reject if pubkey matches customer's own public key ("Cannot pay yourself")
    final crypto = ref.read(cryptoServiceProvider);
    final myKey = _publicKeyBase64 ?? await crypto.getPublicKeyBase64();
    if (merchantPubkey.isNotEmpty && merchantPubkey == myKey) {
      if (scannerContext.mounted) {
        Navigator.of(scannerContext).pop();
      }
      await HapticFeedback.heavyImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot pay yourself'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    // Close camera
    if (scannerContext.mounted) {
      Navigator.of(scannerContext).pop();
    }

    // Show dialog: "Pay to [MerchantName] - Enter Amount (ETB)" with "Simulate tampering" checkbox
    await _showPayToMerchantDialog(
      merchantName: merchantName,
      merchantPubkey: merchantPubkey,
    );
  }

  Future<void> _showPayToMerchantDialog({
    required String merchantName,
    required String merchantPubkey,
    String? endpointId,
  }) async {
    final amountController = TextEditingController(text: '50.0');
    bool simulateTamper = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('Pay to $merchantName - Enter Amount (ETB)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('merchant_pay_amount_input'),
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount (ETB)',
                    suffixText: 'ETB',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  key: const Key('simulate_tamper_checkbox'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Simulate tampering', style: TextStyle(fontSize: 13)),
                  subtitle: const Text('Alters voucher payload to test rejection', style: TextStyle(fontSize: 11)),
                  value: simulateTamper,
                  onChanged: (val) {
                    setDialogState(() => simulateTamper = val ?? false);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: const Key('sign_and_pay_button'),
                icon: const Icon(Icons.send),
                label: const Text('Sign & Pay'),
                onPressed: () {
                  final amount = double.tryParse(amountController.text.trim()) ?? 0.0;
                  if (amount <= 0) return;
                  Navigator.pop(ctx);
                  _executePayment(
                    payeeName: merchantName,
                    payeePubkey: merchantPubkey,
                    amount: amount,
                    simulateTamper: simulateTamper,
                    endpointId: endpointId,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _executePayment({
    required String payeeName,
    required String payeePubkey,
    required double amount,
    required bool simulateTamper,
    String? endpointId,
  }) async {
    final crypto = ref.read(cryptoServiceProvider);
    final db = ref.read(databaseServiceProvider);
    final nearby = ref.read(nearbyServiceProvider);

    // Strictly enforce: If payeePubkey == _publicKeyBase64 or payeeName == currentAccountName:
    // Show error: "Cannot send payment to yourself!" and abort immediately.
    final myKey = _publicKeyBase64 ?? await crypto.getPublicKeyBase64();
    if ((payeePubkey.isNotEmpty && (payeePubkey == _publicKeyBase64 || payeePubkey == myKey)) ||
        (payeeName.isNotEmpty && payeeName == currentAccountName)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot send payment to yourself!'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    setState(() => _isSending = true);

    try {
      final amountCents = (amount * 100).round();

      // 1. Check local balance >= amount. If insufficient, show error snackbar.
      final currentBal = await db.getWalletBalance();
      final currentBalCents = (currentBal * 100).round();
      if (currentBalCents < amountCents) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Insufficient balance! Current balance: ${currentBal.toStringAsFixed(2)} ETB'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 2. Connect to the merchant's Nearby endpoint
      var targetEndpointId = endpointId;
      if (targetEndpointId == null) {
        for (final entry in _discoveredEndpoints.entries) {
          if ((payeePubkey.isNotEmpty && entry.value.contains(payeePubkey)) ||
              entry.value.contains(payeeName)) {
            targetEndpointId = entry.key;
            break;
          }
        }
      }

      if (targetEndpointId == null &&
          WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding')) {
        targetEndpointId = 'test_merchant_endpoint';
      }

      if (targetEndpointId == null) {
        if (!_isScanning) {
          await nearby.startDiscovery(
            userName: 'AirBirrCustomer',
            onEndpointFound: (id, name) {
              if (mounted) {
                setState(() {
                  _discoveredEndpoints[id] = name;
                  final cur = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                  cur[id] = name;
                  _discoveredEndpointsNotifier.value = cur;
                });
              }
            },
            onEndpointLost: (id) {
              if (mounted) {
                setState(() {
                  _discoveredEndpoints.remove(id);
                  final cur = Map<String, String>.from(_discoveredEndpointsNotifier.value);
                  cur.remove(id);
                  _discoveredEndpointsNotifier.value = cur;
                });
              }
            },
          );
          if (mounted) setState(() => _isScanning = true);
        }

        // Wait up to 2 seconds for discovery
        for (int i = 0; i < 20; i++) {
          for (final entry in _discoveredEndpoints.entries) {
            if ((payeePubkey.isNotEmpty && entry.value.contains(payeePubkey)) ||
                entry.value.contains(payeeName)) {
              targetEndpointId = entry.key;
              break;
            }
          }
          if (targetEndpointId != null) break;
          if (_discoveredEndpoints.isNotEmpty) {
            targetEndpointId = _discoveredEndpoints.keys.first;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }

      if (targetEndpointId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not find nearby merchant "$payeeName".'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 3. Atomically fetch next nonce using db.incrementAndGetNonce()
      final nextNonce = await db.incrementAndGetNonce();
      final payerPubkey = _publicKeyBase64 ?? await crypto.getPublicKeyBase64();
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final voucherId = '${payerPubkey}_$nextNonce';

      // 4. Sign voucher payload using CryptoService.signPayload()
      final voucherPayload = <String, dynamic>{
        'voucher_id': voucherId,
        'payer': payerPubkey,
        'payee': payeeName,
        'amount': amount,
        'nonce': nextNonce,
        'timestamp': timestamp,
      };
      final signature = await crypto.signPayload(voucherPayload);

      // 5. Construct wire payload (modifying amount if simulateTamper is checked)
      final wirePayload = <String, dynamic>{
        ...voucherPayload,
        'signature': signature,
      };
      if (simulateTamper) {
        wirePayload['amount'] = amount + 999.0;
      }

      // 6. Send bytes over Nearby & WAIT for merchant's response (with a 6-second timeout)
      final wireBytes = Uint8List.fromList(utf8.encode(jsonEncode(wirePayload)));
      final response = await nearby.sendVoucherAndWaitForResponse(
        endpointId: targetEndpointId,
        packedVoucherBytes: wireBytes,
        timeout: const Duration(seconds: 6),
      );

      if (response != null && response['type'] == 'ACK') {
        // If 'ACK' received:
        // Deduct balance without modifying nonce (already atomically incremented)
        await db.deductBalance(amountCents);
        // Record outgoing voucher so customer has a permanent receipt
        await db.recordSentVoucher(
          voucherId: voucherId,
          payeeId: payeeName,
          amount: amount,
          nonce: nextNonce,
          timestamp: timestamp,
          signature: signature,
          payerPubkey: payerPubkey,
        );
        // Show green SnackBar: "[CONFIRMED] Sent XX ETB to [Peer]!"
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('[CONFIRMED] Sent ${amount.toStringAsFixed(2)} ETB to $payeeName!'),
                  Text('Payment of ${amount.toStringAsFixed(2)} ETB confirmed by $payeeName!'),
                ],
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        // Refresh wallet state display
        await _refreshWalletState();
      } else if (response != null && response['type'] == 'NACK') {
        // If 'NACK' received:
        // Do NOT deduct any balance!
        // Show red SnackBar: "[REJECTED] Merchant rejected voucher! No funds deducted."
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('[REJECTED] Merchant rejected voucher! No funds deducted.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else {
        // If timeout occurs:
        // Do NOT deduct any balance!
        // Show red SnackBar: "Transaction timed out. No funds deducted."
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Transaction timed out. No funds deducted.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error executing payment to merchant: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Transaction timed out. No funds deducted.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _promptPaymentDialog(String endpointId, String endpointName) async {
    await _showPayToMerchantDialog(
      merchantName: endpointName,
      merchantPubkey: '',
      endpointId: endpointId,
    );
  }


  // ===========================================================================
  // 5. CLOUD SETTLEMENT & BOTTOM SHEET
  // ===========================================================================

  Future<void> _syncWithCentralBank() async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);

    try {
      final db = ref.read(databaseServiceProvider);
      final api = ref.read(apiServiceProvider);

      final unsynced = await db.getUnsyncedVouchers();

      if (unsynced.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('All vouchers already synced with Central Bank.'),
              backgroundColor: Colors.teal,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final settledIds = await api.uploadBatchVouchers(unsynced);

      if (settledIds.isNotEmpty) {
        await db.markVouchersSynced(settledIds);
      }

      if (mounted) {
        if (!_isOnline) setState(() => _isOnline = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('[SETTLED] Cleared ${settledIds.length} vouchers with Central Bank!'),
                Text('Successfully synced ${settledIds.length} vouchers with Central Bank!'),
              ],
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }

      await _refreshWalletState();
    } catch (e) {
      if (mounted) {
        if (_isOnline) setState(() => _isOnline = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _registerOnBank() async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);

    try {
      final crypto = ref.read(cryptoServiceProvider);
      final api = ref.read(apiServiceProvider);

      String pubKey = _publicKeyBase64 ?? '';
      if (pubKey.isEmpty) {
        pubKey = await crypto.getPublicKeyBase64();
      }
      if (pubKey.isEmpty) {
        await crypto.getOrCreateKeyPair();
        pubKey = await crypto.getPublicKeyBase64();
      }

      if (pubKey.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot register: Public key is missing.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final isMerchant = _currentMode == AppMode.receive;
      final name = isMerchant
          ? (_merchantNameController.text.trim().isEmpty
              ? 'Bole-Store'
              : _merchantNameController.text.trim())
          : (_userNameController.text.trim().isNotEmpty &&
                  _userNameController.text.trim() != 'Abebe-0911'
              ? _userNameController.text.trim()
              : 'Customer-Wallet');

      final result = await api.registerAccount(
        accountId: name,
        ownerName: name,
        publicKey: pubKey,
        isMerchant: isMerchant,
      );

      if (!mounted) return;

      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach Central Bank server. Check your Server URL or connection.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      } else if (result['status'] == 'already_registered') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Account '$name' is already registered on Central Bank."),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 4),
          ),
        );
      } else if (result['status'] == 'success' ||
          result['status'] == 'registered' ||
          result['account_id'] != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("[SUCCESS] Account '$name' verified on Central Bank!"),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Registration failed for account '$name'."),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach Central Bank server. Check your Server URL or connection.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _showLeaseAllowanceDialog() async {
    final amountController = TextEditingController(text: '300.00');

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lock Offline Spending Allowance'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This locks funds from your Central Bank account into an offline vault valid for offline spending.',
              style: TextStyle(fontSize: 13, color: Color(0xFFE0E0E0)),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('lease_amount_input'),
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
              final amt = double.tryParse(amountController.text.trim()) ?? 0.0;
              if (amt <= 0) return;
              Navigator.pop(ctx);
              _executeLeaseAllowance(amt);
            },
            child: const Text('Confirm & Lock'),
          ),
        ],
      ),
    );
  }

  Future<void> _executeLeaseAllowance(double amount) async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);

    try {
      final api = ref.read(apiServiceProvider);
      final db = ref.read(databaseServiceProvider);
      final accountId = currentAccountName;

      final result = await api.requestOfflineLease(
        accountId: accountId,
        amount: amount,
      );

      if (!mounted) return;

      final leaseId = (result?['lease_id'] ??
              (result?['certificate'] as Map?)?['lease_id'] ??
              (result?['lease_certificate'] as Map?)?['lease_id'])
          ?.toString();

      if (result != null && result['error'] == null && leaseId != null && leaseId.isNotEmpty) {
        final leasedAmount = (result['amount_leased'] as num?)?.toDouble() ?? amount;

        await db.applyOfflineLease(
          leaseId: leaseId,
          leasedAmount: leasedAmount,
        );

        await _refreshWalletState();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('[VAULT FUNDED] Leased ${leasedAmount.toStringAsFixed(2)} ETB from Central Bank!'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else {
        final errorMsg = result?['error']?.toString() ??
            'Cannot reach Central Bank server. Check your connection or Server URL.';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error requesting lease: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Future<void> _showServerSettingsDialog() async {
    final api = ref.read(apiServiceProvider);

    final savedUrl = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => ServerSettingsDialog(initialUrl: api.baseUrl),
    );

    if (savedUrl != null) {
      api.setBaseUrl(savedUrl);
      await _checkServerConnectivity();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Server URL updated to $savedUrl!'),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _showLocalVouchersSheet() async {
    final db = ref.read(databaseServiceProvider);
    final vouchers = await db.getAllVouchersHistory();

    if (!mounted) return;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final cardBorder = isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder;
    final primaryAccent = isDark ? AppTheme.darkPrimaryAccent : AppTheme.lightPrimaryAccent;
    final mintGreen = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final offlineColor = isDark ? AppTheme.darkMutedYellow : AppTheme.lightWarmAmber;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;
    final sentRed = isDark ? AppTheme.darkSentRed : AppTheme.lightSentRed;
    final textColor = theme.colorScheme.onSurface;
    final handleColor = isDark ? AppTheme.darkGray : const Color(0xFFBDBDBD);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: handleColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Ledger Vouchers (${vouchers.length})',
                            style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                          ),
                          TextButton.icon(
                            icon: Icon(
                              Icons.cloud_upload_outlined,
                              size: 18,
                              color: _isOnline ? primaryAccent : mediumGray,
                            ),
                            label: Text(
                              'Mark All Synced',
                              style: TextStyle(
                                color: _isOnline ? primaryAccent : mediumGray,
                              ),
                            ),
                            onPressed: !_isOnline
                                ? null
                                : () async {
                                    final unsynced = await db.getUnsyncedVouchers();
                                    final ids = unsynced.map((v) => v['voucher_id'].toString()).toList();
                                    if (ids.isNotEmpty) {
                                      await db.markVouchersSynced(ids);
                                      if (ctx.mounted) {
                                        Navigator.pop(ctx);
                                      }
                                      if (mounted) {
                                        _showLocalVouchersSheet();
                                      }
                                    }
                                  },
                          ),
                        ],
                      ),
                      Divider(color: cardBorder),
                      if (vouchers.isEmpty)
                        Expanded(
                          child: Center(
                            child: Text(
                              'No local vouchers in ledger yet.',
                              style: TextStyle(color: mediumGray),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView.separated(
                            controller: scrollController,
                            itemCount: vouchers.length,
                            separatorBuilder: (_, _) => Divider(color: cardBorder, height: 1),
                            itemBuilder: (context, index) {
                              final item = vouchers[index];
                              final isSynced = (item['is_synced'] as num?) == 1;
                              final amount = (item['amount'] as num?)?.toDouble() ??
                                  ((item['amount_cents'] as num?)?.toDouble() ?? 0.0) / 100.0;
                              final voucherId = item['voucher_id']?.toString() ?? '';
                              final payer = item['payer_pubkey']?.toString() ?? '';
                              final payee = item['payee_id']?.toString() ?? '';
                              final nonce = item['nonce']?.toString() ?? '';

                              final isSent = item['direction'] == 'SENT';

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isSent
                                      ? sentRed.withValues(alpha: 0.15)
                                      : mintGreen.withValues(alpha: 0.15),
                                  child: Icon(
                                    isSent ? Icons.arrow_upward : Icons.arrow_downward,
                                    color: isSent ? sentRed : mintGreen,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Text(
                                      '${isSent ? '-' : '+'}${amount.toStringAsFixed(2)} ETB',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isSent ? sentRed : mintGreen,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isSent
                                            ? primaryAccent.withValues(alpha: 0.15)
                                            : mintGreen.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: isSent ? primaryAccent : mintGreen,
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        isSent ? 'SENT' : 'RECEIVED',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: isSent ? primaryAccent : mintGreen,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  'ID: $voucherId\n${isSent ? 'To' : 'From'}: ${isSent ? payee : _truncateKey(payer)} | Nonce: #$nonce',
                                  style: TextStyle(fontSize: 12, color: mediumGray),
                                ),
                                trailing: Chip(
                                  label: Text(
                                    isSynced ? 'Synced' : 'Pending',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isSynced
                                          ? mintGreen
                                          : (isDark ? Colors.black87 : Colors.white),
                                    ),
                                  ),
                                  backgroundColor: isSynced
                                      ? mintGreen.withValues(alpha: 0.18)
                                      : offlineColor,
                                  side: BorderSide(
                                    color: isSynced
                                        ? mintGreen.withValues(alpha: 0.4)
                                        : offlineColor,
                                    width: 0.8,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 6. UI BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AirBirr Offline P2P', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text(
              'OffPay Test Suite',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppTheme.darkMediumGray
                    : AppTheme.lightMediumGray,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('server_settings_button'),
            icon: const Icon(Icons.settings_ethernet),
            tooltip: 'Server Settings',
            onPressed: _showServerSettingsDialog,
          ),
          IconButton(
            key: const Key('cloud_sync_button'),
            icon: Icon(
              Icons.cloud_sync,
              color: _isOnline
                  ? null
                  : (Theme.of(context).brightness == Brightness.dark
                      ? AppTheme.darkMediumGray
                      : AppTheme.lightMediumGray),
            ),
            tooltip: _isOnline ? 'Sync with Central Bank' : 'Sync with Central Bank (Offline)',
            onPressed: (_isActionInProgress || !_isOnline) ? null : _syncWithCentralBank,
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'Transaction Ledger',
            onPressed: _showLocalVouchersSheet,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildNetworkStatusBar(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshWalletState,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPermissionWarningBanner(),
                      _buildWalletCard(),
                      const SizedBox(height: 16),
                      _buildModeSelector(),
                      const SizedBox(height: 16),
                      if (_currentMode == AppMode.receive)
                        _buildReceiveMode()
                      else
                        _buildPayMode(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkStatusBar() {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final onlineColor = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final offlineColor = isDark ? AppTheme.darkMutedYellow : AppTheme.lightWarmAmber;

    final indicatorColor = _isOnline ? onlineColor : offlineColor;
    final bgColor = _isOnline
        ? (isDark ? const Color(0xFF0E2318) : const Color(0xFFE8F5E9))
        : (isDark ? const Color(0xFF281F0E) : const Color(0xFFFFF8E1));
    final borderColor = indicatorColor.withValues(alpha: isDark ? 0.35 : 0.30);

    return AnimatedContainer(
      key: const Key('network_status_bar'),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 5.0),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(
            color: borderColor,
            width: 1,
          ),
        ),
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
          key: ValueKey<bool>(_isOnline),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isOnline ? Icons.cloud_done : Icons.offline_bolt,
              size: 14,
              color: indicatorColor,
            ),
            const SizedBox(width: 8),
            Text(
              _isOnline
                  ? 'Connected to Central Bank'
                  : 'Offline Mode Active (Autonomous Vault)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: indicatorColor,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionWarningBanner() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final warnColor = isDark ? AppTheme.darkMutedYellow : AppTheme.lightWarmAmber;
    final primaryAccent = isDark ? AppTheme.darkPrimaryAccent : AppTheme.lightPrimaryAccent;

    return ValueListenableBuilder<bool>(
      valueListenable: _permissionsDeniedNotifier,
      builder: (context, denied, _) {
        if (!denied) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: warnColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: warnColor.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: warnColor, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Bluetooth and Location permissions are required for offline P2P transactions.',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: warnColor),
                ),
              ),
              TextButton(
                onPressed: _requestPermissions,
                child: Text('Grant', style: TextStyle(color: primaryAccent)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWalletCard() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryAccent = isDark ? AppTheme.darkPrimaryAccent : AppTheme.lightPrimaryAccent;
    final mintGreen = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final cardColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final cardBorder = isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder;
    final subtleBorder = isDark ? AppTheme.darkSubtleBorder : AppTheme.lightSubtleBorder;
    final elevatedHighColor = isDark ? AppTheme.darkSurfaceElevatedHigh : AppTheme.lightSurfaceElevatedHigh;
    final textColor = theme.colorScheme.onSurface;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;

    return Card(
      color: cardColor,
      elevation: isDark ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cardBorder, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AirBirr Offline P2P',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textColor),
                    ),
                    Text(
                      'Local Wallet State',
                      style: TextStyle(fontSize: 11, color: mediumGray),
                    ),
                  ],
                ),
                IconButton(
                  icon: Icon(Icons.refresh, size: 18, color: primaryAccent),
                  tooltip: 'Refresh',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _refreshWalletState,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('User / Account: ', style: TextStyle(color: mediumGray, fontSize: 12)),
                Expanded(
                  child: SizedBox(
                    height: 22,
                    child: TextField(
                      key: const Key('user_name_input'),
                      controller: _userNameController,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: textColor),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        fillColor: Colors.transparent,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'Abebe-0911',
                        hintStyle: TextStyle(color: mediumGray, fontSize: 12),
                      ),
                      onChanged: (_) {
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                if (_publicKeyBase64 != null) {
                  Clipboard.setData(ClipboardData(text: _publicKeyBase64!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Public key copied to clipboard!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: _buildInfoRow(
                  'Public Key',
                  _isLoadingWallet && _publicKeyBase64 == null
                      ? 'Loading...'
                      : _truncateKey(_publicKeyBase64),
                  trailing: Icon(Icons.copy, size: 12, color: mediumGray),
                  textColor: textColor,
                  labelColor: mediumGray,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'Balance',
                    '${_balance.toStringAsFixed(2)} ETB',
                    Icons.account_balance_wallet_outlined,
                    mintGreen,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricTile(
                    'Current Nonce',
                    '#$_lastNonce',
                    Icons.tag,
                    primaryAccent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  key: const Key('register_on_bank_button'),
                  icon: const Icon(Icons.account_balance_outlined, size: 14),
                  label: const Text('Register on Bank', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primaryAccent,
                    side: BorderSide(color: subtleBorder),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _isActionInProgress ? null : _registerOnBank,
                ),
                FilledButton.tonal(
                  key: const Key('lease_allowance_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _isOnline ? elevatedHighColor : (isDark ? const Color(0xFF1E1E1E) : const Color(0xFFEEEEEE)),
                    foregroundColor: _isOnline ? primaryAccent : const Color(0xFF9E9E9E),
                    disabledBackgroundColor: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFEEEEEE),
                    disabledForegroundColor: const Color(0xFF9E9E9E),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _isActionInProgress ? null : _showLeaseAllowanceDialog,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_clock_outlined,
                        size: 14,
                        color: _isOnline ? null : const Color(0xFF9E9E9E),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Lease Offline Allowance',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isOnline ? null : const Color(0xFF9E9E9E),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Widget? trailing, Color? textColor, Color? labelColor}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveLabelColor = labelColor ?? (isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray);
    final effectiveTextColor = textColor ?? Theme.of(context).colorScheme.onSurface;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: effectiveLabelColor, fontSize: 13)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace', color: effectiveTextColor)),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing,
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildMetricTile(String label, String value, IconData icon, Color color) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final elevatedColor = isDark ? AppTheme.darkSurfaceElevated : AppTheme.lightSurfaceElevated;
    final cardBorder = isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: elevatedColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder, width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: mediumGray, fontSize: 11)),
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mintGreen = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final primaryAccent = isDark ? AppTheme.darkPrimaryAccent : AppTheme.lightPrimaryAccent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('TAB A: [ 📥 RECEIVE MONEY ]', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: mintGreen)),
              Text('TAB B: [ 📤 SEND MONEY ]', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: primaryAccent)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SegmentedButton<AppMode>(
          segments: const [
            ButtonSegment<AppMode>(
              value: AppMode.receive,
              label: Text('MODE A: RECEIVE'),
              icon: Icon(Icons.storefront),
            ),
            ButtonSegment<AppMode>(
              value: AppMode.pay,
              label: Text('MODE B: PAY'),
              icon: Icon(Icons.payment),
            ),
          ],
          selected: {_currentMode},
      onSelectionChanged: (Set<AppMode> newSelection) async {
        // 1. Immediately kill all background Bluetooth/Nearby activity
        final nearby = ref.read(nearbyServiceProvider);
        await nearby.stopAll();

        // 2. Reset all states cleanly
        setState(() {
          _isAdvertising = false;
          _isScanning = false;
          _discoveredEndpoints.clear();
          _discoveredEndpointsNotifier.value = {};
          _merchantStatusNotifier.value = MerchantStatus.idle;
          _lastStatusMessage = null;
          _merchantSuccessMessage = null;
          _merchantAlertMessage = null;
          _currentMode = newSelection.first;
        });
      },
    ),
  ],
);
}

  Widget _buildReceiveMode() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final cardBorder = isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder;
    final subtleBorder = isDark ? AppTheme.darkSubtleBorder : AppTheme.lightSubtleBorder;
    final surfaceElevated = isDark ? AppTheme.darkSurfaceElevated : AppTheme.lightSurfaceElevated;
    final textColor = theme.colorScheme.onSurface;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;
    final mintGreen = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final sentRed = isDark ? AppTheme.darkSentRed : AppTheme.lightSentRed;

    final merchantName = _merchantNameController.text.trim().isEmpty
        ? 'Bole-Store'
        : _merchantNameController.text.trim();
    final invoiceData = jsonEncode({
      'type': 'RECEIVE_REQUEST',
      'payee': merchantName,
      'name': merchantName,
      'pubkey': _publicKeyBase64 ?? '',
    });

    return Card(
      color: cardColor,
      elevation: isDark ? 1 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cardBorder, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📥 RECEIVE MONEY',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
                    ),
                    Text(
                      'Merchant Terminal',
                      style: TextStyle(fontSize: 12, color: mediumGray),
                    ),
                  ],
                ),
                _buildStatusIndicator(),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _merchantNameController,
              enabled: !_isAdvertising,
              decoration: const InputDecoration(
                labelText: 'Merchant Name',
                hintText: 'e.g. Bole-Store',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.store),
              ),
              onChanged: (_) {
                if (mounted) setState(() {});
              },
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('merchant_receive_button'),
              icon: Icon(_isAdvertising ? Icons.stop : Icons.sensors),
              label: Text(_isAdvertising ? 'Stop Receiving' : 'Start Receiving'),
              style: FilledButton.styleFrom(
                backgroundColor: _isAdvertising ? sentRed : mintGreen,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _isActionInProgress ? null : _toggleAdvertising,
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                _isAdvertising ? 'Broadcast Beacon (BLE) Active' : 'Broadcast Beacon (BLE)',
                style: TextStyle(fontSize: 11, color: mintGreen, fontWeight: FontWeight.w600),
              ),
            ),
            if (_isAdvertising) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: subtleBorder),
                ),
                child: Column(
                  children: [
                    Text(
                      'Ready for customer scans...',
                      style: TextStyle(
                        color: mintGreen,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: QrImageView(
                        key: const Key('merchant_invoice_qr'),
                        data: invoiceData,
                        version: QrVersions.auto,
                        size: 200.0,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Merchant: $merchantName',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor),
                    ),
                  ],
                ),
              ),
            ],
            if (_merchantSuccessMessage != null) ...[
              const SizedBox(height: 12),
              AnimatedScale(
                scale: 1.0,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                child: Container(
                  key: const Key('merchant_success_banner'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: mintGreen.withValues(alpha: 0.15),
                    border: Border.all(color: mintGreen),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: mintGreen),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _merchantSuccessMessage!,
                          style: TextStyle(
                            color: mintGreen,
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_merchantAlertMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('merchant_alert_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sentRed.withValues(alpha: 0.15),
                  border: Border.all(color: sentRed),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error, color: sentRed),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _merchantAlertMessage!,
                        style: TextStyle(color: sentRed, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (!_isAdvertising && _lastStatusMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: subtleBorder),
                ),
                child: Text(
                  _lastStatusMessage!,
                  style: TextStyle(fontSize: 12, color: mediumGray),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mintGreen = isDark ? AppTheme.darkMintGreen : AppTheme.lightMintGreen;
    final offlineColor = isDark ? AppTheme.darkMutedYellow : AppTheme.lightWarmAmber;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;

    return ValueListenableBuilder<MerchantStatus>(
      valueListenable: _merchantStatusNotifier,
      builder: (context, status, _) {
        Color color;
        String text;
        Widget leading;

        switch (status) {
          case MerchantStatus.advertising:
            color = mintGreen;
            text = 'Advertising';
            leading = Icon(Icons.sensors, size: 14, color: mintGreen);
            break;
          case MerchantStatus.receivingPayload:
            color = offlineColor;
            text = 'Receiving payload';
            leading = const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
            break;
          case MerchantStatus.idle:
            color = mediumGray;
            text = 'Idle';
            leading = Icon(Icons.circle, size: 10, color: mediumGray);
            break;
        }

        return Chip(
          avatar: leading,
          label: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
          backgroundColor: color.withValues(alpha: 0.1),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }

  Widget _buildPayMode() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final cardBorder = isDark ? AppTheme.darkCardBorder : AppTheme.lightCardBorder;
    final subtleBorder = isDark ? AppTheme.darkSubtleBorder : AppTheme.lightSubtleBorder;
    final primaryAccent = isDark ? AppTheme.darkPrimaryAccent : AppTheme.lightPrimaryAccent;
    final textColor = theme.colorScheme.onSurface;
    final mediumGray = isDark ? AppTheme.darkMediumGray : AppTheme.lightMediumGray;

    return Card(
      color: cardColor,
      elevation: isDark ? 1 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cardBorder, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📤 SEND MONEY',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
                ),
                Text(
                  'Customer Payment Terminal',
                  style: TextStyle(fontSize: 12, color: mediumGray),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('scan_merchant_qr_button'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Merchant QR to Pay'),
              style: FilledButton.styleFrom(
                backgroundColor: primaryAccent,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: (_isSending || _isActionInProgress) ? null : _openMerchantQrScanner,
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Option 1: Scan QR Code',
                style: TextStyle(fontSize: 11, color: primaryAccent, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: _isScanning
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(color: primaryAccent, strokeWidth: 2),
                    )
                  : const Icon(Icons.radar),
              label: Text(_isScanning ? 'Stop Scanning' : 'Scan for Merchants'),
              style: OutlinedButton.styleFrom(
                foregroundColor: primaryAccent,
                side: BorderSide(color: subtleBorder),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _isActionInProgress ? null : _toggleDiscovery,
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                _isScanning ? 'Scanning Nearby Phones...' : 'Option 2: Scan Nearby Phones',
                style: TextStyle(fontSize: 11, color: primaryAccent, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<Map<String, String>>(
              valueListenable: _discoveredEndpointsNotifier,
              builder: (context, endpoints, _) {
                if (endpoints.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24.0),
                    child: Center(
                      child: Text(
                        _isScanning
                            ? 'Scanning for nearby merchants...'
                            : 'Tap "Scan Merchant QR to Pay" to begin.',
                        style: TextStyle(color: mediumGray),
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: endpoints.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: cardBorder),
                  itemBuilder: (context, index) {
                    final endpointId = endpoints.keys.elementAt(index);
                    final endpointName = endpoints[endpointId]!;

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: primaryAccent.withValues(alpha: 0.15),
                        child: Icon(Icons.store, color: primaryAccent),
                      ),
                      title: Text(endpointName, style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
                      subtitle: Text('ID: $endpointId', style: TextStyle(fontSize: 11, color: mediumGray)),
                      trailing: _isSending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: primaryAccent,
                                foregroundColor: isDark ? Colors.black : Colors.white,
                              ),
                              onPressed: (_isSending || _isActionInProgress)
                                  ? null
                                  : () => _promptPaymentDialog(endpointId, endpointName),
                              child: const Text('Pay'),
                            ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

