import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_learning/main.dart';
import 'package:flutter_learning/services/api_service.dart';
import 'package:flutter_learning/services/crypto_service.dart';
import 'package:flutter_learning/services/database_service.dart';
import 'package:flutter_learning/services/nearby_service.dart';
import 'package:flutter_learning/theme/app_theme.dart';

class FakeApiService extends ApiService {
  List<Map<String, dynamic>> lastUploadedVouchers = [];
  List<String> nextSettledIds = [];

  @override
  Future<bool> checkHealth({Duration timeout = const Duration(seconds: 2)}) async {
    return forcedOnlineStatus ?? true;
  }

  @override
  Future<List<String>> uploadBatchVouchers(List<Map<String, dynamic>> unsyncedVouchers) async {
    lastUploadedVouchers = List.from(unsyncedVouchers);
    return nextSettledIds.isNotEmpty
        ? nextSettledIds
        : unsyncedVouchers.map((v) => v['voucher_id'].toString()).toList();
  }
}

class FakeNearbyService extends NearbyService {
  bool advertising = false;
  bool discovering = false;
  String? advertisedMerchantName;
  Function(String endpointId, Uint8List payload)? onPayloadReceivedCallback;
  final List<Uint8List> sentResponsePayloads = [];
  Map<String, dynamic>? nextSendVoucherResponse;

  @override
  bool get isAdvertising => advertising;

  @override
  bool get isDiscovering => discovering;

  @override
  Future<bool> startAdvertising({
    required String merchantName,
    required Function(String endpointId, Uint8List payload) onPayloadReceived,
  }) async {
    advertising = true;
    advertisedMerchantName = merchantName;
    onPayloadReceivedCallback = onPayloadReceived;
    return true;
  }

  @override
  Future<bool> stopAdvertising() async {
    advertising = false;
    return true;
  }

  @override
  Future<bool> startDiscovery({
    required Function(String endpointId, String endpointName) onEndpointFound,
    required Function(String endpointId) onEndpointLost,
    String userName = 'OffPayCustomer',
  }) async {
    discovering = true;
    return true;
  }

  @override
  Future<bool> stopDiscovery() async {
    discovering = false;
    return true;
  }

  @override
  Future<bool> stopAll() async {
    advertising = false;
    discovering = false;
    return true;
  }

  @override
  Future<bool> sendResponsePayload(String endpointId, Uint8List payload) async {
    sentResponsePayloads.add(payload);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> sendVoucherAndWaitForResponse({
    required String endpointId,
    required Uint8List packedVoucherBytes,
    String clientName = 'OffPayPayer',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    return nextSendVoucherResponse;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
  const nearbyChannel = MethodChannel('nearby_connections');

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});

    const nearbyEventChannel = MethodChannel('nearby_connections/events');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestPermissions') {
        final permissions = call.arguments as List<dynamic>;
        return {for (var p in permissions) p: 1};
      }
      return 1;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nearbyChannel, (call) async => true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nearbyEventChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nearbyChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nearby_connections/events'), null);
  });

  Future<void> waitForWalletReady(WidgetTester tester) async {
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('500.00 ETB').evaluate().isNotEmpty) {
        break;
      }
    }
  }

  testWidgets('Renders OffPay Test Suite and switches between Receive and Pay modes',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Verify App Bar & Title
    expect(find.text('OffPay Test Suite'), findsOneWidget);

    // Verify Wallet State Card
    expect(find.text('Local Wallet State'), findsOneWidget);
    expect(find.text('Balance'), findsOneWidget);
    expect(find.text('Current Nonce'), findsOneWidget);

    // Verify default MODE A: RECEIVE
    expect(find.text('Merchant Terminal'), findsOneWidget);
    expect(find.text('Start Receiving'), findsOneWidget);
    expect(find.text('Bole-Store'), findsOneWidget);

    // Switch to MODE B: PAY
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    // Verify MODE B elements
    expect(find.text('Customer Payment Terminal'), findsOneWidget);
    expect(find.text('Scan Merchant QR to Pay'), findsOneWidget);
    expect(find.text('Scan for Merchants'), findsOneWidget);

    // Tap Transaction Ledger icon button in AppBar
    await tester.tap(find.byTooltip('Transaction Ledger'));
    await tester.pump();
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('Ledger Vouchers').evaluate().isNotEmpty) {
        break;
      }
    }

    // Verify bottom sheet appears
    expect(find.textContaining('Ledger Vouchers'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE A: Merchant starts receiving, shows invoice QR code and live status',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Verify initial idle state
    expect(find.text('Start Receiving'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    // Tap Start Receiving
    await tester.tap(find.text('Start Receiving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify active receiving state
    expect(find.text('Stop Receiving'), findsOneWidget);
    expect(find.text('Ready for customer scans...'), findsOneWidget);
    expect(find.byKey(const Key('merchant_invoice_qr')), findsOneWidget);
    expect(fakeNearby.advertising, isTrue);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE A: Merchant verifies incoming valid customer voucher and displays green success banner',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Tap Start Receiving
    await tester.tap(find.text('Start Receiving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Create an external customer voucher signed with Ed25519
    final customerAlgo = Ed25519();
    final customerKey = await customerAlgo.newKeyPair();
    final customerPubKeyBytes = (await customerKey.extractPublicKey()).bytes;
    final customerPubKey = base64Encode(customerPubKeyBytes);

    final voucherPayload = {
      'voucher_id': '${customerPubKey}_1',
      'payer': customerPubKey,
      'payee': 'Bole-Store',
      'amount': 50.0,
      'nonce': 1,
      'timestamp': 1712345678,
    };
    final canonicalBytes = utf8.encode(CryptoService.canonicalJson(voucherPayload));
    final sig = await customerAlgo.sign(canonicalBytes, keyPair: customerKey);
    final wirePayload = {
      ...voucherPayload,
      'signature': base64Encode(sig.bytes),
    };
    final wireBytes = Uint8List.fromList(utf8.encode(jsonEncode(wirePayload)));

    // Simulate incoming payload from customer
    await tester.runAsync(() async {
      await fakeNearby.onPayloadReceivedCallback!('client_endpoint_1', wireBytes);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify ACK sent back to customer
    expect(fakeNearby.sentResponsePayloads.isNotEmpty, isTrue);
    final lastSentJson = jsonDecode(utf8.decode(fakeNearby.sentResponsePayloads.last));
    expect(lastSentJson['type'], equals('ACK'));
    expect(lastSentJson['status'], equals('CONFIRMED'));
    expect(lastSentJson['voucher_id'], equals('${customerPubKey}_1'));

    // Verify green success banner appears on merchant screen
    expect(find.byKey(const Key('merchant_success_banner')), findsOneWidget);
    expect(find.textContaining('[SUCCESS] Received 50.00 ETB'), findsOneWidget);

    // Verify merchant balance credited: 500.00 + 50.00 = 550.00 ETB
    expect(find.text('550.00 ETB'), findsOneWidget);

    // Verify voucher stored in SQLite
    List<Map<String, dynamic>> vouchers = [];
    await tester.runAsync(() async {
      vouchers = await testDbService.getAllVouchersHistory();
    });
    expect(vouchers.length, equals(1));
    expect(vouchers.first['amount'], equals(50.0));
    expect(vouchers.first['payer_pubkey'], equals(customerPubKey));

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE A: Merchant handles duplicate voucher idempotently',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);
    await tester.tap(find.text('Start Receiving'));
    await tester.pump();

    final customerAlgo = Ed25519();
    final customerKey = await customerAlgo.newKeyPair();
    final customerPubKeyBytes = (await customerKey.extractPublicKey()).bytes;
    final customerPubKey = base64Encode(customerPubKeyBytes);

    final voucherPayload = {
      'voucher_id': '${customerPubKey}_1',
      'payer': customerPubKey,
      'payee': 'Bole-Store',
      'amount': 30.0,
      'nonce': 1,
      'timestamp': 1712345678,
    };
    final canonicalBytes = utf8.encode(CryptoService.canonicalJson(voucherPayload));
    final sig = await customerAlgo.sign(canonicalBytes, keyPair: customerKey);
    final wirePayload = {
      ...voucherPayload,
      'signature': base64Encode(sig.bytes),
    };
    final wireBytes = Uint8List.fromList(utf8.encode(jsonEncode(wirePayload)));

    // Send first time
    await tester.runAsync(() async {
      await fakeNearby.onPayloadReceivedCallback!('client_1', wireBytes);
    });
    await tester.pump();
    expect(find.text('530.00 ETB'), findsOneWidget);

    // Send duplicate second time
    fakeNearby.sentResponsePayloads.clear();
    await tester.runAsync(() async {
      await fakeNearby.onPayloadReceivedCallback!('client_1', wireBytes);
    });
    await tester.pump();

    // Verify ACK is re-sent immediately
    expect(fakeNearby.sentResponsePayloads.length, equals(1));
    final ack = jsonDecode(utf8.decode(fakeNearby.sentResponsePayloads.first));
    expect(ack['type'], equals('ACK'));
    expect(ack['status'], equals('CONFIRMED'));

    // Balance remains 530.00 ETB (not double-credited)
    expect(find.text('530.00 ETB'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE A: Merchant rejects tampered voucher',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);
    await tester.tap(find.text('Start Receiving'));
    await tester.pump();

    // Create a tampered voucher
    final tamperedPayload = {
      'voucher_id': 'tampered_voucher_1',
      'payer': base64Encode(List.filled(32, 2)),
      'payee': 'Bole-Store',
      'amount': 999.0,
      'nonce': 1,
      'timestamp': 1712345678,
      'signature': base64Encode(List.filled(64, 0)),
    };
    final wireBytes = Uint8List.fromList(utf8.encode(jsonEncode(tamperedPayload)));

    await tester.runAsync(() async {
      await fakeNearby.onPayloadReceivedCallback!('client_1', wireBytes);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify NACK was sent
    expect(fakeNearby.sentResponsePayloads.isNotEmpty, isTrue);
    final nack = jsonDecode(utf8.decode(fakeNearby.sentResponsePayloads.last));
    expect(nack['type'], equals('NACK'));
    expect(nack['status'], equals('REJECTED'));
    expect(nack['reason'], equals('Invalid Signature'));

    // Verify red alert banner appears on merchant screen
    expect(find.byKey(const Key('merchant_alert_banner')), findsOneWidget);
    expect(find.text('[ALERT] Rejected invalid/tampered voucher!'), findsWidgets);

    // Balance remains untouched: 500.00 ETB
    expect(find.text('500.00 ETB'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE B: Customer scans merchant QR code and completes payment with ACK',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    // Mock merchant ACK response
    fakeNearby.nextSendVoucherResponse = {
      'type': 'ACK',
      'voucher_id': 'voucher_1',
      'status': 'CONFIRMED',
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Switch to MODE B: PAY
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    // Tap Scan Merchant QR to Pay
    await tester.tap(find.byKey(const Key('scan_merchant_qr_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(QrScannerScreen), findsOneWidget);

    // Merchant invoice QR payload
    final merchantPubKey = base64Encode(List.filled(32, 5));
    final invoiceJson = jsonEncode({
      'type': 'MERCHANT_INVOICE',
      'name': 'Bole-Store',
      'pubkey': merchantPubKey,
    });

    // Enter QR payload via manual entry dialog
    await tester.tap(find.byTooltip('Enter code manually'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('manual_qr_input')), invoiceJson);
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(QrScannerScreen).evaluate().isEmpty &&
          find.text('Pay to Bole-Store - Enter Amount (ETB)').evaluate().isNotEmpty) {
        break;
      }
    }

    // Payment dialog is now shown
    expect(find.text('Pay to Bole-Store - Enter Amount (ETB)'), findsOneWidget);
    expect(find.byKey(const Key('sign_and_pay_button')), findsOneWidget);

    // Set amount to 50.0
    await tester.enterText(find.byKey(const Key('merchant_pay_amount_input')), '50.0');
    await tester.pump();

    // Tap Sign & Pay
    await tester.tap(find.byKey(const Key('sign_and_pay_button')));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('450.00 ETB').evaluate().isNotEmpty) break;
    }

    // Balance deducted: 500.00 - 50.00 = 450.00 ETB
    expect(find.text('450.00 ETB'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('Payment of 50.00 ETB confirmed by Bole-Store!'), findsOneWidget);

    // Verify recordSentVoucher was stored in local ledger
    final history = await tester.runAsync(() => testDbService.getAllVouchersHistory());
    expect(history!.length, equals(1));
    expect(history.first['direction'], equals('SENT'));
    expect(history.first['amount'], equals(50.0));
    expect(history.first['payee_id'], equals('Bole-Store'));

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE B: Customer rejects self-payment when scanning own merchant QR',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    final cryptoService = CryptoService();
    final myKey = await cryptoService.getPublicKeyBase64();

    // Switch to MODE B: PAY
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    // Tap Scan Merchant QR to Pay
    await tester.tap(find.byKey(const Key('scan_merchant_qr_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Merchant invoice with self key
    final selfInvoice = jsonEncode({
      'type': 'MERCHANT_INVOICE',
      'name': 'Self-Store',
      'pubkey': myKey,
    });

    await tester.tap(find.byTooltip('Enter code manually'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('manual_qr_input')), selfInvoice);
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(QrScannerScreen).evaluate().isEmpty &&
          find.text('Cannot pay yourself').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.byType(QrScannerScreen), findsNothing);
    expect(find.text('Cannot pay yourself'), findsOneWidget);

    // Balance remains untouched: 500.00 ETB
    expect(find.text('500.00 ETB'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE B: _executePayment rejects self-payment when payee name matches current account name',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Switch to MODE B: PAY
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    // Tap Scan Merchant QR to Pay
    await tester.tap(find.byKey(const Key('scan_merchant_qr_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Merchant invoice with different pubkey but same account name ('Abebe-0911')
    final otherKey = base64Encode(List.filled(32, 42));
    final selfNameInvoice = jsonEncode({
      'type': 'MERCHANT_INVOICE',
      'name': 'Abebe-0911',
      'pubkey': otherKey,
    });

    await tester.tap(find.byTooltip('Enter code manually'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('manual_qr_input')), selfNameInvoice);
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(QrScannerScreen).evaluate().isEmpty &&
          find.text('Pay to Abebe-0911 - Enter Amount (ETB)').evaluate().isNotEmpty) {
        break;
      }
    }

    // Dialog appears: Tap Sign & Pay
    expect(find.text('Pay to Abebe-0911 - Enter Amount (ETB)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sign_and_pay_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify "Cannot send payment to yourself!" SnackBar appears
    expect(find.text('Cannot send payment to yourself!'), findsOneWidget);

    // Balance untouched
    expect(find.text('500.00 ETB'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE B: Customer simulates tampering and merchant sends NACK',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    // Mock merchant NACK response
    fakeNearby.nextSendVoucherResponse = {
      'type': 'NACK',
      'voucher_id': 'voucher_tampered',
      'status': 'REJECTED',
      'reason': 'Invalid Signature',
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('scan_merchant_qr_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final merchantPubKey = base64Encode(List.filled(32, 7));
    final invoiceJson = jsonEncode({
      'type': 'MERCHANT_INVOICE',
      'name': 'Bole-Store',
      'pubkey': merchantPubKey,
    });

    await tester.tap(find.byTooltip('Enter code manually'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('manual_qr_input')), invoiceJson);
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(QrScannerScreen).evaluate().isEmpty) break;
    }

    // Check Simulate tampering checkbox
    await tester.tap(find.byKey(const Key('simulate_tamper_checkbox')));
    await tester.pump();

    // Tap Sign & Pay
    await tester.tap(find.byKey(const Key('sign_and_pay_button')));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('[REJECTED] Merchant rejected voucher! No funds deducted.').evaluate().isNotEmpty) {
        break;
      }
    }

    // SnackBar appears
    expect(find.text('[REJECTED] Merchant rejected voucher! No funds deducted.'), findsOneWidget);

    // Balance remains untouched: 500.00 ETB and #0
    expect(find.text('500.00 ETB'), findsOneWidget);
    expect(find.text('#0'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('MODE B: Customer payment times out when merchant does not respond',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    // Mock null response (timeout)
    fakeNearby.nextSendVoucherResponse = null;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    await tester.tap(find.text('MODE B: PAY'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('scan_merchant_qr_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final merchantPubKey = base64Encode(List.filled(32, 9));
    final invoiceJson = jsonEncode({
      'type': 'MERCHANT_INVOICE',
      'name': 'Bole-Store',
      'pubkey': merchantPubKey,
    });

    await tester.tap(find.byTooltip('Enter code manually'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('manual_qr_input')), invoiceJson);
    await tester.pump();
    await tester.tap(find.text('Submit'));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(QrScannerScreen).evaluate().isEmpty) break;
    }

    // Tap Sign & Pay
    await tester.tap(find.byKey(const Key('sign_and_pay_button')));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Transaction timed out. No funds deducted.').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.text('Transaction timed out. No funds deducted.'), findsOneWidget);

    // Balance remains untouched: 500.00 ETB and #0
    expect(find.text('500.00 ETB'), findsOneWidget);
    expect(find.text('#0'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Cloud Sync button with empty unsynced vouchers shows message',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Tap Cloud Sync in AppBar
    await tester.tap(find.byKey(const Key('cloud_sync_button')));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('All vouchers already synced with Central Bank.').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.text('All vouchers already synced with Central Bank.'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Cloud Sync button with unsynced vouchers uploads batch and marks them synced',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    // Insert an unsynced voucher
    await tester.runAsync(() async {
      await testDbService.recordSentVoucher(
        voucherId: 'test_sync_v1',
        payeeId: 'Bole-Store',
        amount: 100.0,
        nonce: 1,
        timestamp: 1700000000,
        signature: 'test_sig',
        payerPubkey: 'payer_pubkey',
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Tap Cloud Sync in AppBar
    await tester.tap(find.byKey(const Key('cloud_sync_button')));
    await tester.pump();

    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('Successfully synced 1 vouchers with Central Bank!').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.text('Successfully synced 1 vouchers with Central Bank!'), findsOneWidget);

    // Verify marked synced in DB
    final unsynced = await tester.runAsync(() => testDbService.getUnsyncedVouchers());
    expect(unsynced, isEmpty);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Server Settings dialog opens, validates input, and updates baseUrl',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();
    fakeApi.baseUrl = 'http://192.168.132.10:8000';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Tap Server Settings in AppBar
    expect(find.byKey(const Key('server_settings_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('server_settings_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Dialog title and prefilled URL
    expect(find.text('Central Bank Server URL'), findsOneWidget);
    expect(find.text('http://192.168.132.10:8000'), findsOneWidget);

    // Test Cancel button
    await tester.tap(find.byKey(const Key('server_url_cancel_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    expect(fakeApi.baseUrl, equals('http://192.168.132.10:8000'));

    // Reopen dialog
    await tester.tap(find.byKey(const Key('server_settings_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Test invalid URL validation
    await tester.enterText(find.byKey(const Key('server_url_input')), 'ftp://invalid-server');
    await tester.pump();
    await tester.tap(find.byKey(const Key('server_url_save_button')));
    await tester.pump();

    // Dialog stays open and shows error
    expect(find.text('URL must start with http:// or https://'), findsOneWidget);
    expect(fakeApi.baseUrl, equals('http://192.168.132.10:8000'));

    // Test valid URL with trailing slash
    await tester.enterText(find.byKey(const Key('server_url_input')), 'http://192.168.1.15:8000///');
    await tester.pump();
    await tester.tap(find.byKey(const Key('server_url_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Dialog closes
    expect(find.byType(AlertDialog), findsNothing);

    // Verify baseUrl was updated on ApiService
    expect(fakeApi.baseUrl, equals('http://192.168.1.15:8000'));

    // Verify SnackBar
    expect(find.text('Server URL updated to http://192.168.1.15:8000!'), findsOneWidget);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('System theme mode with light and dark themes is configured on MaterialApp',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, equals(ThemeMode.system));

    // Light theme validation
    final lightTheme = materialApp.theme!;
    expect(lightTheme.brightness, equals(Brightness.light));
    expect(lightTheme.scaffoldBackgroundColor, equals(AppTheme.lightBackground));
    expect(lightTheme.colorScheme.surface, equals(AppTheme.lightSurface));
    expect(lightTheme.colorScheme.primary, equals(AppTheme.lightPrimaryAccent));
    expect(lightTheme.colorScheme.secondary, equals(AppTheme.lightMintGreen));

    // Dark theme validation
    final darkTheme = materialApp.darkTheme!;
    expect(darkTheme.brightness, equals(Brightness.dark));
    expect(darkTheme.scaffoldBackgroundColor, equals(AppTheme.darkBackground));
    expect(darkTheme.colorScheme.surface, equals(AppTheme.darkSurface));
    expect(darkTheme.colorScheme.primary, equals(AppTheme.darkPrimaryAccent));
    expect(darkTheme.colorScheme.secondary, equals(AppTheme.darkMintGreen));

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Network status bar adapts offline indicator colors dynamically based on brightness',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();
    fakeApi.forcedOnlineStatus = false;

    addTearDown(() => tester.platformDispatcher.clearPlatformBrightnessTestValue());

    // 1. Test in Dark Mode (Muted Yellow #FFD54F)
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );
    await waitForWalletReady(tester);

    final offlineTextDark = tester.widget<Text>(find.text('Offline Mode Active (Autonomous Vault)'));
    expect(offlineTextDark.style?.color, equals(AppTheme.darkMutedYellow));

    // 2. Test in Light Mode (Warm Amber #F57F17)
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final offlineTextLight = tester.widget<Text>(find.text('Offline Mode Active (Autonomous Vault)'));
    expect(offlineTextLight.style?.color, equals(AppTheme.lightWarmAmber));

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Network status bar displays online Connected to Central Bank when server is online',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();
    fakeApi.forcedOnlineStatus = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    expect(find.byKey(const Key('network_status_bar')), findsOneWidget);
    expect(find.text('Connected to Central Bank'), findsOneWidget);

    final syncBtn = tester.widget<IconButton>(find.byKey(const Key('cloud_sync_button')));
    expect(syncBtn.onPressed, isNotNull);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Network status bar displays offline banner and disables Cloud Sync when offline, but local P2P works',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();
    fakeApi.forcedOnlineStatus = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Verify offline status bar
    expect(find.byKey(const Key('network_status_bar')), findsOneWidget);
    expect(find.text('Offline Mode Active (Autonomous Vault)'), findsOneWidget);

    // Verify cloud sync button is disabled
    final syncBtn = tester.widget<IconButton>(find.byKey(const Key('cloud_sync_button')));
    expect(syncBtn.onPressed, isNull);

    // Verify local P2P is fully interactive
    expect(find.text('Start Receiving'), findsOneWidget);
    await tester.tap(find.text('Start Receiving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Stop Receiving'), findsOneWidget);
    expect(fakeNearby.advertising, isTrue);

    await tester.runAsync(() => testDbService.close());
  });

  testWidgets('Ledger sheet displays RECEIVED and SENT badges with proper styling and Muted Yellow pending chips',
      timeout: const Timeout(Duration(seconds: 30)),
      (WidgetTester tester) async {
    final testDbService = DatabaseService(customDbPath: inMemoryDatabasePath);
    final fakeNearby = FakeNearbyService();
    final fakeApi = FakeApiService();
    fakeApi.forcedOnlineStatus = false;

    // Seed one received and one sent voucher
    await tester.runAsync(() async {
      await testDbService.recordSentVoucher(
        voucherId: 'sent_voucher_01',
        payeeId: 'Bole-Store',
        amount: 45.0,
        nonce: 1,
        timestamp: 1700000000,
        signature: 'sig_sent',
        payerPubkey: 'payer_pub',
      );

      await testDbService.recordReceivedVoucher(
        voucherId: 'recv_voucher_01',
        payerPubkey: 'customer_pub',
        payeeId: 'Bole-Store',
        amount: 75.0,
        nonce: 2,
        timestamp: 1700000001,
        signature: 'sig_recv',
      );

      // Mark sent voucher as synced
      await testDbService.markVouchersSynced(['sent_voucher_01']);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(testDbService),
          nearbyServiceProvider.overrideWithValue(fakeNearby),
          apiServiceProvider.overrideWithValue(fakeApi),
        ],
        child: const OffPayApp(),
      ),
    );

    await waitForWalletReady(tester);

    // Open transaction ledger sheet
    await tester.tap(find.byTooltip('Transaction Ledger'));
    await tester.pump();
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('Ledger Vouchers').evaluate().isNotEmpty) break;
    }

    // Verify direction badges
    expect(find.text('SENT'), findsOneWidget);
    expect(find.text('RECEIVED'), findsOneWidget);

    // Verify pending and synced chips
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Synced'), findsOneWidget);

    // Verify Mark All Synced is disabled when offline
    final markSyncedBtn = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Mark All Synced'));
    expect(markSyncedBtn.onPressed, isNull);

    await tester.runAsync(() => testDbService.close());
  });
}
