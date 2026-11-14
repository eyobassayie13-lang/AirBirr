import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_learning/main.dart';
import 'package:flutter_learning/screens/main_shell.dart';
import 'package:flutter_learning/screens/pin_login_screen.dart';
import 'package:flutter_learning/screens/register_screen.dart';
import 'package:flutter_learning/services/api_service.dart';
import 'package:flutter_learning/services/crypto_service.dart';
import 'package:flutter_learning/services/database_service.dart';
import 'package:flutter_learning/services/nearby_service.dart';
import 'package:flutter_learning/theme/app_theme.dart';
import 'package:flutter_learning/utils/phone_utils.dart';

class MockPinAuthApiService extends ApiService {
  @override
  Future<bool> checkHealth({Duration timeout = const Duration(seconds: 2)}) async => true;

  @override
  Future<Map<String, dynamic>?> registerAccount({
    required String accountId,
    required String ownerName,
    required String publicKey,
    bool isMerchant = false,
  }) async {
    return {'status': 'success', 'account_id': accountId};
  }
}

class MockPinAuthNearbyService extends NearbyService {
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

  const MethodChannel permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
  const MethodChannel nearbyChannel = MethodChannel('nearby_connections');

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

  Future<void> waitForPredicate(
    WidgetTester tester,
    bool Function() predicate, {
    int maxTicks = 40,
  }) async {
    for (int i = 0; i < maxTicks; i++) {
      if (predicate()) return;
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('PART 1: Desktop SQLite Initialization', () {
    test('Platform check and driver initialization on desktop', () {
      final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
      expect(isDesktop, isTrue); // running under linux test environment
      expect(databaseFactory, equals(databaseFactoryFfi));
    });
  });

  group('PART 2: Ethiopian Phone Number Validator (PhoneUtils)', () {
    test('normalizes all supported Ethiopian phone formats to 10-digit 09... or 07...', () {
      expect(PhoneUtils.normalizeEthiopianPhone('+251911223344'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('+251711223344'), equals('0711223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('251911223344'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('911223344'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('0911223344'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('0711223344'), equals('0711223344'));
    });

    test('strips whitespace, hyphens, and parentheses', () {
      expect(PhoneUtils.normalizeEthiopianPhone('+251 (911) 22-33-44'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('0911 22 33 44'), equals('0911223344'));
      expect(PhoneUtils.normalizeEthiopianPhone('  0711-223-344  '), equals('0711223344'));
    });

    test('rejects invalid prefixes, non-digits, and invalid lengths', () {
      expect(PhoneUtils.normalizeEthiopianPhone('0811223344'), isNull);
      expect(PhoneUtils.normalizeEthiopianPhone('0111223344'), isNull);
      expect(PhoneUtils.normalizeEthiopianPhone('12345'), isNull);
      expect(PhoneUtils.normalizeEthiopianPhone(''), isNull);
      expect(PhoneUtils.normalizeEthiopianPhone('091122334499'), isNull);
      expect(PhoneUtils.normalizeEthiopianPhone('091122334a'), isNull);
    });

    test('isValidEthiopianPhone returns true only for valid numbers', () {
      expect(PhoneUtils.isValidEthiopianPhone('+251911223344'), isTrue);
      expect(PhoneUtils.isValidEthiopianPhone('0711223344'), isTrue);
      expect(PhoneUtils.isValidEthiopianPhone('0811223344'), isFalse);
      expect(PhoneUtils.isValidEthiopianPhone('invalid'), isFalse);
    });
  });

  group('PART 3: 6-Digit PIN Setup in Registration', () {
    testWidgets('Validates Ethiopian phone number and creates 6-digit PIN in secure storage', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      final mockApi = MockPinAuthApiService();
      final mockNearby = MockPinAuthNearbyService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(mockApi),
            nearbyServiceProvider.overrideWithValue(mockNearby),
          ],
          child: const MaterialApp(
            home: RegisterScreen(),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);

      // Verify fields exist
      expect(find.byKey(const Key('register_account_id_input')), findsOneWidget);
      expect(find.byKey(const Key('register_display_name_input')), findsOneWidget);
      expect(find.byKey(const Key('register_pin_input')), findsOneWidget);
      expect(find.byKey(const Key('register_confirm_pin_input')), findsOneWidget);

      // Enter international format phone number and custom PIN
      await tester.enterText(find.byKey(const Key('register_account_id_input')), '+251 912 345 678');
      await tester.enterText(find.byKey(const Key('register_display_name_input')), 'Selamawit Tadesse');
      await tester.enterText(find.byKey(const Key('register_pin_input')), '654321');
      await tester.enterText(find.byKey(const Key('register_confirm_pin_input')), '654321');
      await tester.pump();

      // Submit registration
      await tester.ensureVisible(find.byKey(const Key('register_submit_button')));
      await tester.tap(find.byKey(const Key('register_submit_button')));
      await tester.pump();

      await waitForPredicate(tester, () => find.byType(MainShellScreen).evaluate().isNotEmpty);
      expect(find.byType(MainShellScreen), findsOneWidget);

      // Verify PIN stored in FlutterSecureStorage
      const storage = FlutterSecureStorage();
      final storedPin = await storage.read(key: 'user_wallet_pin');
      expect(storedPin, equals('654321'));

      // Verify normalized phone stored in SQLite database
      final profile = await tester.runAsync(() => testDb.getUserProfile());
      expect(profile?['account_id'], equals('0912345678'));
      expect(profile?['display_name'], equals('Selamawit Tadesse'));

      await tester.runAsync(() => testDb.close());
    });

    testWidgets('Shows error if PIN entries do not match', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
          ],
          child: const MaterialApp(
            home: RegisterScreen(),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);

      await tester.enterText(find.byKey(const Key('register_account_id_input')), '0911223344');
      await tester.enterText(find.byKey(const Key('register_pin_input')), '111111');
      await tester.enterText(find.byKey(const Key('register_confirm_pin_input')), '222222');
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('register_submit_button')));
      await tester.tap(find.byKey(const Key('register_submit_button')));
      await tester.pump();

      expect(find.text('PINs do not match'), findsOneWidget);
      await tester.runAsync(() => testDb.close());
    });
  });

  group('PART 4: 6-Digit PIN Login Screen (PinLoginScreen)', () {
    testWidgets('Displays branding, greeting, and authenticates with matching PIN', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'user_wallet_pin': '123456',
      });

      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() => testDb.saveUserProfile(accountId: '0911223344', displayName: 'Abebe Kebede'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(MockPinAuthApiService()),
            nearbyServiceProvider.overrideWithValue(MockPinAuthNearbyService()),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            home: const PinLoginScreen(
              profile: {
                'account_id': '0911223344',
                'display_name': 'Abebe Kebede',
              },
            ),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty);

      // 1. Branding & Greeting
      expect(find.text('AirBirr'), findsOneWidget);
      expect(find.text('Welcome back, Abebe Kebede'), findsOneWidget);

      // 2. Tap keypad: 1 2 3 4 5 6
      for (final digit in ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.byKey(Key('keypad_$digit')));
        await tester.pump(const Duration(milliseconds: 30));
      }

      await waitForPredicate(tester, () => find.byType(MainShellScreen).evaluate().isNotEmpty);
      expect(find.byType(MainShellScreen), findsOneWidget);

      for (int i = 0; i < 5; i++) {
        await tester.runAsync(() async => await Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.runAsync(() => testDb.close());
    });

    testWidgets('Handles backspace and shows error with red indicators on incorrect PIN', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'user_wallet_pin': '654321',
      });

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: PinLoginScreen(
              profile: {
                'account_id': '0911223344',
                'display_name': 'Dawit',
              },
            ),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty);

      // Tap digits 1, 2, then backspace, then 1, 1, 1, 1, 1, 1 (wrong PIN)
      await tester.tap(find.byKey(const Key('keypad_1')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.byKey(const Key('keypad_2')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.byKey(const Key('keypad_backspace')));
      await tester.pump(const Duration(milliseconds: 20));

      // Enter 1 1 1 1 1 1
      for (int i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('keypad_1')));
        await tester.pump(const Duration(milliseconds: 20));
      }

      await waitForPredicate(tester, () => find.byKey(const Key('pin_error_text')).evaluate().isNotEmpty);

      // Error text is displayed
      expect(find.byKey(const Key('pin_error_text')), findsOneWidget);
      expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);

      // Wait for error flash timer to clear
      await tester.pump(const Duration(milliseconds: 700));
    });

    testWidgets('Reset Wallet button opens confirmation dialog and clears storage', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'user_wallet_pin': '123456',
      });

      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() => testDb.saveUserProfile(accountId: '0911223344', displayName: 'Abebe'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
          ],
          child: const MaterialApp(
            home: PinLoginScreen(
              profile: {'account_id': '0911223344', 'display_name': 'Abebe'},
            ),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty);

      // Tap Reset Wallet button
      await tester.ensureVisible(find.byKey(const Key('reset_wallet_button')));
      await tester.tap(find.byKey(const Key('reset_wallet_button')));
      await tester.pump(const Duration(milliseconds: 50));

      // Verify dialog is shown
      expect(find.text('Reset Wallet?'), findsOneWidget);

      // Tap confirm Reset Wallet in dialog
      await tester.tap(find.widgetWithText(FilledButton, 'Reset Wallet'));
      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);

      // Navigates to RegisterScreen
      expect(find.byType(RegisterScreen), findsOneWidget);

      // Check PIN deleted
      const storage = FlutterSecureStorage();
      final pin = await storage.read(key: 'user_wallet_pin');
      expect(pin, isNull);

      // Check user profile cleared in db
      final isReg = await tester.runAsync(() => testDb.isUserRegistered());
      expect(isReg, isFalse);

      await tester.runAsync(() => testDb.close());
    });
  });

  group('PART 5: Auth Gatekeeper & Lock Wallet', () {
    testWidgets('Unregistered user -> RegisterScreen', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      FlutterSecureStorage.setMockInitialValues({});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);
      expect(find.byType(RegisterScreen), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    });

    testWidgets('Registered user without PIN -> RegisterScreen', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() => testDb.saveUserProfile(accountId: '0911223344', displayName: 'Registered User'));
      FlutterSecureStorage.setMockInitialValues({}); // No PIN

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(RegisterScreen).evaluate().isNotEmpty);
      expect(find.byType(RegisterScreen), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    });

    testWidgets('Registered user with PIN -> PinLoginScreen', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() => testDb.saveUserProfile(accountId: '0911223344', displayName: 'Abebe Kebede'));
      FlutterSecureStorage.setMockInitialValues({
        'user_wallet_pin': '123456',
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
          ],
          child: const OffPayApp(forceGatekeeper: true),
        ),
      );

      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty);
      expect(find.byType(PinLoginScreen), findsOneWidget);
      expect(find.text('Welcome back, Abebe Kebede'), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    });

    testWidgets('Lock Wallet button on MainShellScreen locks and navigates to PinLoginScreen', (tester) async {
      final testDb = DatabaseService(customDbPath: inMemoryDatabasePath);
      await tester.runAsync(() async {
        await testDb.saveUserProfile(accountId: '0911223344', displayName: 'Abebe Kebede');
        await testDb.initWalletState(initialBalanceCents: 10000, leaseId: 'lease_1');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(testDb),
            apiServiceProvider.overrideWithValue(MockPinAuthApiService()),
            nearbyServiceProvider.overrideWithValue(MockPinAuthNearbyService()),
          ],
          child: const MaterialApp(
            home: MainShellScreen(
              profile: {
                'account_id': '0911223344',
                'display_name': 'Abebe Kebede',
                'is_merchant': false,
              },
            ),
          ),
        ),
      );

      await waitForPredicate(tester, () => find.byKey(const Key('lock_wallet_button')).evaluate().isNotEmpty);

      // Find and tap Lock Wallet button
      expect(find.byKey(const Key('lock_wallet_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('lock_wallet_button')));
      await tester.pump();

      // Should now be on PinLoginScreen
      await waitForPredicate(tester, () => find.byType(PinLoginScreen).evaluate().isNotEmpty);
      expect(find.byType(PinLoginScreen), findsOneWidget);
      expect(find.text('Welcome back, Abebe Kebede'), findsOneWidget);

      await tester.runAsync(() => testDb.close());
    });
  });
}
