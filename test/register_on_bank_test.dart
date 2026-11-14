import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_learning/main.dart';
import 'package:flutter_learning/services/api_service.dart';
import 'package:flutter_learning/services/database_service.dart';
import 'package:flutter_learning/services/nearby_service.dart';

class MockRegisterApiService extends ApiService {
  Map<String, dynamic>? nextRegisterResult = {'status': 'success'};
  Map<String, dynamic>? nextLeaseResult = {
    'lease_id': 'lease_mock_123',
    'amount_leased': 300.0,
    'remaining_online_balance': 700.0,
    'certificate': {
      'lease_id': 'lease_mock_123',
      'payer_pubkey': 'mock_pubkey',
      'max_allowance': 300.0,
      'expires_at': 1700000000,
      'signature': 'mock_sig',
    },
  };
  String? lastAccountId;
  String? lastOwnerName;
  String? lastPublicKey;
  bool? lastIsMerchant;
  String? lastLeaseAccountId;
  double? lastLeaseAmount;

  @override
  Future<Map<String, dynamic>?> registerAccount({
    required String accountId,
    required String ownerName,
    required String publicKey,
    bool isMerchant = false,
  }) async {
    lastAccountId = accountId;
    lastOwnerName = ownerName;
    lastPublicKey = publicKey;
    lastIsMerchant = isMerchant;
    return nextRegisterResult;
  }

  @override
  Future<Map<String, dynamic>?> requestOfflineLease({
    required String accountId,
    required double amount,
    int durationDays = 7,
  }) async {
    lastLeaseAccountId = accountId;
    lastLeaseAmount = amount;
    return nextLeaseResult;
  }
}

class FakeNearbyServiceForRegister extends NearbyService {
  @override
  bool get isAdvertising => false;
  @override
  bool get isDiscovering => false;
  @override
  Future<bool> stopAll() async => true;
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
        .setMockMethodCallHandler(permissionChannel, (call) async => 1);
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

  Future<void> pumpOffPayApp(
    WidgetTester tester, {
    required MockRegisterApiService apiService,
    required DatabaseService dbService,
    required FakeNearbyServiceForRegister nearbyService,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(dbService),
          nearbyServiceProvider.overrideWithValue(nearbyService),
          apiServiceProvider.overrideWithValue(apiService),
        ],
        child: const OffPayApp(),
      ),
    );

    await tester.pump();
    // Allow wallet initialization
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('500.00 ETB').evaluate().isNotEmpty) break;
    }
  }

  testWidgets('Register on Bank button is displayed on Wallet State card', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    expect(find.text('Register on Bank'), findsOneWidget);
    expect(find.text('Lease Offline Allowance'), findsOneWidget);
  });

  testWidgets('Merchant mode: registers as merchant and shows green success SnackBar', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextRegisterResult = {'status': 'success'};
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    // Tap Register on Bank in default merchant mode (Bole-Store)
    await tester.tap(find.text('Register on Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.lastAccountId, equals('Bole-Store'));
    expect(api.lastOwnerName, equals('Bole-Store'));
    expect(api.lastIsMerchant, isTrue);
    expect(api.lastPublicKey, isNotNull);

    expect(find.text("[SUCCESS] Account 'Bole-Store' verified on Central Bank!"), findsOneWidget);
  });

  testWidgets('Merchant mode: shows already registered SnackBar when account exists', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextRegisterResult = {'status': 'already_registered', 'account_id': 'Bole-Store'};
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    await tester.tap(find.text('Register on Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("Account 'Bole-Store' is already registered on Central Bank."), findsOneWidget);
  });

  testWidgets('Merchant mode: shows unreachable message when server cannot be reached', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextRegisterResult = null;
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    await tester.tap(find.text('Register on Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Cannot reach Central Bank server. Check your Server URL or connection.'), findsOneWidget);
  });

  testWidgets('Customer mode: registers as Customer-Wallet and shows success SnackBar', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextRegisterResult = {'status': 'success'};
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    // Switch to Pay (Customer) mode
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pumpAndSettle();

    // Tap Register on Bank
    await tester.tap(find.text('Register on Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.lastAccountId, equals('Customer-Wallet'));
    expect(api.lastOwnerName, equals('Customer-Wallet'));
    expect(api.lastIsMerchant, isFalse);
    expect(api.lastPublicKey, isNotNull);

    expect(find.text("[SUCCESS] Account 'Customer-Wallet' verified on Central Bank!"), findsOneWidget);
  });

  testWidgets('Customer mode: shows already registered SnackBar when Customer-Wallet already registered', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextRegisterResult = {'status': 'already_registered', 'account_id': 'Customer-Wallet'};
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    // Switch to Pay mode
    await tester.tap(find.text('MODE B: PAY'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Register on Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text("Account 'Customer-Wallet' is already registered on Central Bank."), findsOneWidget);
  });

  testWidgets('Lease Offline Allowance workflow: opens dialog, submits amount, updates vault and shows success SnackBar', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextLeaseResult = {
      'lease_id': 'lease_xyz_999',
      'amount_leased': 300.0,
      'remaining_online_balance': 700.0,
      'certificate': {
        'lease_id': 'lease_xyz_999',
        'payer_pubkey': 'mock_pubkey',
        'max_allowance': 300.0,
        'expires_at': 1700000000,
        'signature': 'mock_sig',
      },
    };
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    // Tap "Lease Offline Allowance" button
    expect(find.text('Lease Offline Allowance'), findsOneWidget);
    await tester.tap(find.text('Lease Offline Allowance'));
    await tester.pumpAndSettle();

    // Verify dialog appears
    expect(find.text('Lock Offline Spending Allowance'), findsOneWidget);
    expect(
      find.text('This locks funds from your Central Bank account into an offline vault valid for offline spending.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('lease_amount_input')), findsOneWidget);
    expect(find.text('300.00'), findsOneWidget);

    // Tap "Confirm & Lock"
    await tester.tap(find.byKey(const Key('confirm_lease_button')));
    await tester.pump();
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('[VAULT FUNDED] Leased 300.00 ETB from Central Bank!').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(api.lastLeaseAmount, equals(300.0));
    expect(find.text('[VAULT FUNDED] Leased 300.00 ETB from Central Bank!'), findsOneWidget);

    // Verify vault balance updated in DB
    final state = await tester.runAsync(() => db.getWalletState());
    expect(state!['offline_balance_cents'], equals(30000));
    expect(state['current_nonce'], equals(0));
    expect(state['active_lease_id'], equals('lease_xyz_999'));
  });

  testWidgets('Lease Offline Allowance workflow: shows red error SnackBar on failure', (WidgetTester tester) async {
    final db = DatabaseService(customDbPath: inMemoryDatabasePath);
    final api = MockRegisterApiService();
    api.nextLeaseResult = {
      'error': 'Insufficient online balance. Current: 50.00 ETB, Requested: 300.00 ETB',
    };
    final nearby = FakeNearbyServiceForRegister();

    await pumpOffPayApp(tester, apiService: api, dbService: db, nearbyService: nearby);

    await tester.tap(find.text('Lease Offline Allowance'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('confirm_lease_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Insufficient online balance. Current: 50.00 ETB, Requested: 300.00 ETB'), findsOneWidget);
  });
}
