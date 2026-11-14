import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_learning/main.dart';
import 'package:flutter_learning/screens/ledger_screen.dart';
import 'package:flutter_learning/screens/main_shell.dart';
import 'package:flutter_learning/screens/pin_login_screen.dart';
import 'package:flutter_learning/screens/receive_screen.dart';
import 'package:flutter_learning/screens/register_screen.dart';
import 'package:flutter_learning/screens/send_screen.dart';
import 'package:flutter_learning/services/api_service.dart';
import 'package:flutter_learning/services/crypto_service.dart';
import 'package:flutter_learning/services/database_service.dart';
import 'package:flutter_learning/services/nearby_service.dart';

class MockMultiScreenApiService extends ApiService {
  Map<String, dynamic>? registerResult = {'status': 'success'};

  @override
  Future<bool> checkHealth({Duration timeout = const Duration(seconds: 2)}) async {
    return true;
  }

  @override
  Future<Map<String, dynamic>?> registerAccount({
    required String accountId,
    required String ownerName,
    required String publicKey,
    bool isMerchant = false,
  }) async {
    return registerResult;
  }

  @override
  Future<Map<String, dynamic>?> requestOfflineLease({
    required String accountId,
    required double amount,
    int durationDays = 7,
  }) async {
    return {
      'lease_id': 'lease_multi_test_123',
      'amount_leased': amount,
      'remaining_online_balance': 500.0,
      'certificate': {
        'lease_id': 'lease_multi_test_123',
        'payer_pubkey': 'mock_key',
        'max_allowance': amount,
        'expires_at': 1700000000,
        'signature': 'mock_sig',
      },
    };
  }
}

class MockMultiScreenNearbyService extends NearbyService {
  @override
  bool get isAdvertising => false;
  @override
  bool get isDiscovering => false;
  @override
  Future<bool> stopAll() async => true;
  @override
  Future<bool> stopAdvertising() async => true;
  @override
  Future<bool> stopDiscovery() async => true;
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
    final mockSeed = base64Encode(List.filled(32, 1));
    FlutterSecureStorage.setMockInitialValues({
      CryptoService.privateKeyStorageKey: mockSeed,
      'user_wallet_pin': '123456',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async => 1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nearbyChannel, (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nearby_connections/events'), (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nearbyChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nearby_connections/events'), null);
  });

  Future<void> waitForPredicate(WidgetTester tester, bool Function() predicate, {int maxTicks = 40}) async {
    for (int i = 0; i < maxTicks; i++) {
      if (predicate()) return;
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'AppGatekeeper displays RegisterScreen when wallet is unregistered',
    timeout: const Timeout(Duration(seconds: 15)),
    (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      final mockApi = MockMultiScreenApiService();
      final mockNearby = MockMultiScreenNearbyService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(mockApi),
            nearbyServiceProvider.overrideWithValue(mockNearby),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);

      // Verify RegisterScreen is presented
      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.text('AirBirr'), findsOneWidget);
      expect(find.text('Autonomous Offline Peer-to-Peer Payments'), findsOneWidget);
      expect(find.byKey(const Key('register_account_id_input')), findsOneWidget);
      expect(find.byKey(const Key('register_display_name_input')), findsOneWidget);
      expect(find.byKey(const Key('register_submit_button')), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    },
  );

  testWidgets(
    'RegisterScreen registers wallet and navigates to MainNavigationShell',
    timeout: const Timeout(Duration(seconds: 15)),
    (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      final mockApi = MockMultiScreenApiService();
      final mockNearby = MockMultiScreenNearbyService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(mockApi),
            nearbyServiceProvider.overrideWithValue(mockNearby),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);

      // Fill registration form
      await tester.enterText(find.byKey(const Key('register_account_id_input')), '0988776655');
      await tester.enterText(find.byKey(const Key('register_display_name_input')), 'Kalkidan Store');
      await tester.pump();

      // Tap submit button
      await tester.tap(find.byKey(const Key('register_submit_button')));
      await tester.pump();

      await waitForPredicate(tester, () => find.byType(MainNavigationShell).evaluate().isNotEmpty);

      // Verify navigation into MainNavigationShell
      expect(find.byType(MainNavigationShell), findsOneWidget);
      expect(find.text('Hello, Kalkidan Store'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);
      expect(find.text('Ledger'), findsOneWidget);

      // Verify SQLite profile was persisted
      final isRegistered = await tester.runAsync(() => testDb.isWalletRegistered());
      expect(isRegistered, isTrue);

      await tester.runAsync(() => testDb.close());
    },
  );

  testWidgets(
    'MainNavigationShell allows switching between Home, Send, Receive, and Ledger',
    timeout: const Timeout(Duration(seconds: 15)),
    (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() async {
        await testDb.saveUserProfile(
          accountId: '0911223344',
          displayName: 'Abebe Kebede',
        );
        await testDb.initWalletState(initialBalanceCents: 45000, leaseId: 'lease_abc');
      });

      final mockApi = MockMultiScreenApiService();
      final mockNearby = MockMultiScreenNearbyService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(mockApi),
            nearbyServiceProvider.overrideWithValue(mockNearby),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty || find.byType(MainNavigationShell).evaluate().isNotEmpty);

      if (find.byType(PinLoginScreen).evaluate().isNotEmpty) {
        for (final digit in ['1', '2', '3', '4', '5', '6']) {
          await tester.tap(find.byKey(Key('keypad_$digit')));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }

      await waitForPredicate(tester, () => find.byType(MainNavigationShell).evaluate().isNotEmpty);

      // 1. Initial screen: Home
      expect(find.text('Hello, Abebe Kebede'), findsOneWidget);
      await waitForPredicate(tester, () => find.text('450.00 ETB').evaluate().isNotEmpty);
      expect(find.text('450.00 ETB'), findsOneWidget);
      expect(find.byKey(const Key('lease_allowance_button')), findsOneWidget);

      // 2. Switch to Send tab
      await tester.tap(find.text('Send'));
      await tester.pump();
      await waitForPredicate(tester, () => find.byType(SendScreen).evaluate().isNotEmpty);
      expect(find.text('Scan Merchant Invoice'), findsOneWidget);

      // 3. Switch to Receive tab
      await tester.tap(find.text('Receive'));
      await tester.pump();
      await waitForPredicate(tester, () => find.byType(ReceiveScreen).evaluate().isNotEmpty);
      expect(find.byKey(const Key('toggle_beacon_button')), findsOneWidget);

      // 4. Switch to Ledger tab
      await tester.tap(find.text('Ledger'));
      await tester.pump();
      await waitForPredicate(tester, () => find.byType(LedgerScreen).evaluate().isNotEmpty);

      await tester.runAsync(() => testDb.close());
    },
  );

  testWidgets(
    'SendScreen rejects self-payment when entering payee with matching account name',
    timeout: const Timeout(Duration(seconds: 15)),
    (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() async {
        await testDb.saveUserProfile(
          accountId: '0911223344',
          displayName: 'Abebe Kebede',
        );
        await testDb.initWalletState(initialBalanceCents: 50000, leaseId: 'lease_xyz');
      });

      final mockApi = MockMultiScreenApiService();
      final mockNearby = MockMultiScreenNearbyService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(mockApi),
            nearbyServiceProvider.overrideWithValue(mockNearby),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SendScreen(
                profile: {
                  'account_id': '0911223344',
                  'display_name': 'Abebe Kebede',
                },
                onPaymentCompleted: _noOp,
              ),
            ),
          ),
        ),
      );

      for (int i = 0; i < 40; i++) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
        final state = tester.state(find.byType(SendScreen)) as dynamic;
        if (state.myPublicKeyBase64 != null) break;
      }

      final sendState = tester.state(find.byType(SendScreen)) as dynamic;
      sendState.handleQrScannedForTest('airbirr://pay?pubkey=other_key&name=Abebe%20Kebede');
      await tester.pump();

      // Verify self payment was rejected
      expect(find.text('Cannot send payment to yourself!'), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    },
  );
}

void _noOp() {}
