import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_learning/services/crypto_service.dart';
import 'package:flutter_learning/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService dbService;

  setUp(() async {
    // Use in-memory SQLite database for clean test isolation
    dbService = DatabaseService(customDbPath: inMemoryDatabasePath);
  });

  tearDown(() async {
    await dbService.close();
  });

  group('DatabaseService - OffPay Core Requirements', () {
    test('initWalletState seeds and resets wallet state correctly', () async {
      await dbService.initWalletState(
        initialBalanceCents: 50000, // 500.00 ETB
        leaseId: 'lease-test-uuid',
      );

      final state = await dbService.getWalletState();
      expect(state['id'], equals(1));
      expect(state['offline_balance_cents'], equals(50000));
      expect(state['current_nonce'], equals(0));
      expect(state['next_nonce'], equals(1));
      expect(state['active_lease_id'], equals('lease-test-uuid'));

      // Re-seeding with a new lease resets current_nonce and sets new balance
      await dbService.initWalletState(
        initialBalanceCents: 25000,
        leaseId: 'lease-renewed-uuid',
      );

      final reseeded = await dbService.getWalletState();
      expect(reseeded['offline_balance_cents'], equals(25000));
      expect(reseeded['current_nonce'], equals(0));
      expect(reseeded['next_nonce'], equals(1));
      expect(reseeded['active_lease_id'], equals('lease-renewed-uuid'));
    });

    test('deductBalanceAndIncrementNonce succeeds with sufficient balance', () async {
      await dbService.initWalletState(
        initialBalanceCents: 10000, // 100.00 ETB
        leaseId: 'lease-deduct-test',
      );

      // Deduct 30.00 ETB (3000 cents)
      final success1 = await dbService.deductBalanceAndIncrementNonce(3000);
      expect(success1, isTrue);

      final state1 = await dbService.getWalletState();
      expect(state1['offline_balance_cents'], equals(7000));
      expect(state1['current_nonce'], equals(1));
      expect(state1['next_nonce'], equals(2));

      // Deduct another 70.00 ETB (7000 cents) down to exactly 0
      final success2 = await dbService.deductBalanceAndIncrementNonce(7000);
      expect(success2, isTrue);

      final state2 = await dbService.getWalletState();
      expect(state2['offline_balance_cents'], equals(0));
      expect(state2['current_nonce'], equals(2));
      expect(state2['next_nonce'], equals(3));
    });

    test('deductBalanceAndIncrementNonce rolls back and returns false on insufficient balance', () async {
      await dbService.initWalletState(
        initialBalanceCents: 2000, // 20.00 ETB
        leaseId: 'lease-fail-test',
      );

      // Attempt to deduct more than available balance (25.00 ETB)
      final success = await dbService.deductBalanceAndIncrementNonce(2500);
      expect(success, isFalse);

      // Verify that balance and nonce remain strictly untouched
      final state = await dbService.getWalletState();
      expect(state['offline_balance_cents'], equals(2000));
      expect(state['current_nonce'], equals(0));
      expect(state['next_nonce'], equals(1));
    });

    test('recordReceivedVoucher logs verified voucher correctly', () async {
      final mockKey = Uint8List(32)..fillRange(0, 32, 7);
      final rawBytes = Uint8List.fromList(List.filled(124, 0xAA));

      final payload = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'merchant_01',
        amountInCents: 1550,
        nonce: 1,
        timestampSeconds: 1713000000,
      );

      final recorded = await dbService.recordReceivedVoucher(
        payload: payload,
        rawBytes: rawBytes,
      );
      expect(recorded, isTrue);

      final unsynced = await dbService.getUnsyncedVouchers();
      expect(unsynced.length, equals(1));
      expect(unsynced.first['payee_id'], equals('merchant_01'));
      expect(unsynced.first['amount_cents'], equals(1550));
      expect(unsynced.first['amount'], equals(15.50));
      expect(unsynced.first['nonce'], equals(1));
      expect(unsynced.first['timestamp'], equals(1713000000));
      expect(unsynced.first['is_synced'], equals(0));
      expect(unsynced.first['raw_bytes'], equals(rawBytes));
    });

    test('recordReceivedVoucher rejects duplicate voucher (replay prevention)', () async {
      final mockKey = Uint8List(32)..fillRange(0, 32, 9);
      final rawBytes = Uint8List.fromList(List.filled(124, 0xBB));

      final payload = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'merchant_02',
        amountInCents: 4200,
        nonce: 5,
        timestampSeconds: 1713000100,
      );

      final firstInsert = await dbService.recordReceivedVoucher(
        payload: payload,
        rawBytes: rawBytes,
      );
      expect(firstInsert, isTrue);

      // Second attempt with the exact same voucher payload must return false (replay prevention)
      final duplicateInsert = await dbService.recordReceivedVoucher(
        payload: payload,
        rawBytes: rawBytes,
      );
      expect(duplicateInsert, isFalse);

      // Ledger must still contain exactly one entry
      final all = await dbService.getAllVouchersHistory();
      expect(all.length, equals(1));
    });

    test('getAllVouchersHistory returns records ordered by timestamp DESC', () async {
      final mockKey = Uint8List(32)..fillRange(0, 32, 3);

      final v1 = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'merchant_01',
        amountInCents: 1000,
        nonce: 1,
        timestampSeconds: 1000,
      );
      final v2 = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'merchant_01',
        amountInCents: 2000,
        nonce: 2,
        timestampSeconds: 3000,
      );
      final v3 = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'merchant_01',
        amountInCents: 3000,
        nonce: 3,
        timestampSeconds: 2000,
      );

      await dbService.recordReceivedVoucher(payload: v1, rawBytes: Uint8List(124));
      await dbService.recordReceivedVoucher(payload: v2, rawBytes: Uint8List(124));
      await dbService.recordReceivedVoucher(payload: v3, rawBytes: Uint8List(124));

      final history = await dbService.getAllVouchersHistory();
      expect(history.length, equals(3));
      // Must be ordered by timestamp DESC: v2 (3000), v3 (2000), v1 (1000)
      expect(history[0]['timestamp'], equals(3000));
      expect(history[1]['timestamp'], equals(2000));
      expect(history[2]['timestamp'], equals(1000));
    });

    test('markVouchersSynced updates is_synced = 1 for specified vouchers', () async {
      final mockKey = Uint8List(32)..fillRange(0, 32, 4);

      final v1 = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'm1',
        amountInCents: 100,
        nonce: 10,
        timestampSeconds: 10,
      );
      final v2 = VoucherPayload(
        payerPublicKey: mockKey,
        payeeId: 'm2',
        amountInCents: 200,
        nonce: 11,
        timestampSeconds: 11,
      );

      await dbService.recordReceivedVoucher(payload: v1, rawBytes: Uint8List(124));
      await dbService.recordReceivedVoucher(payload: v2, rawBytes: Uint8List(124));

      final unsyncedBefore = await dbService.getUnsyncedVouchers();
      expect(unsyncedBefore.length, equals(2));

      final id1 = unsyncedBefore.firstWhere((e) => e['nonce'] == 10)['voucher_id'] as String;
      final id2 = unsyncedBefore.firstWhere((e) => e['nonce'] == 11)['voucher_id'] as String;

      await dbService.markVouchersSynced([id1]);

      final unsyncedAfter = await dbService.getUnsyncedVouchers();
      expect(unsyncedAfter.length, equals(1));
      expect(unsyncedAfter.first['voucher_id'], equals(id2));

      await dbService.markVouchersSynced([id2]);
      expect(await dbService.getUnsyncedVouchers(), isEmpty);
    });

    test('recordSentVoucher stores outgoing voucher with direction = SENT and replay prevention', () async {
      final success1 = await dbService.recordSentVoucher(
        voucherId: 'sent_voucher_1',
        payeeId: 'Bole-Store',
        amount: 45.50,
        nonce: 1,
        timestamp: 1000,
        signature: 'mock_sent_sig',
        payerPubkey: 'customer_pubkey',
      );
      expect(success1, isTrue);

      final vouchers = await dbService.getAllVouchersHistory();
      expect(vouchers.length, equals(1));
      expect(vouchers.first['voucher_id'], equals('sent_voucher_1'));
      expect(vouchers.first['direction'], equals('SENT'));
      expect(vouchers.first['amount'], equals(45.50));
      expect(vouchers.first['payee_id'], equals('Bole-Store'));
      expect(vouchers.first['is_synced'], equals(0));

      // Replay prevention: duplicate voucherId returns false
      final success2 = await dbService.recordSentVoucher(
        voucherId: 'sent_voucher_1',
        payeeId: 'Bole-Store',
        amount: 45.50,
        nonce: 1,
        timestamp: 1000,
        signature: 'mock_sent_sig',
        payerPubkey: 'customer_pubkey',
      );
      expect(success2, isFalse);
    });

    test('getAllVouchersHistory returns both SENT and RECEIVED vouchers ordered by timestamp DESC', () async {
      final mockKey = Uint8List(32)..fillRange(0, 32, 1);

      // 1. Received voucher at t=100
      await dbService.recordReceivedVoucher(
        payload: VoucherPayload(
          payerPublicKey: mockKey,
          payeeId: 'merchant_me',
          amountInCents: 1000,
          nonce: 1,
          timestampSeconds: 100,
        ),
        rawBytes: Uint8List(124),
      );

      // 2. Sent voucher at t=300
      await dbService.recordSentVoucher(
        voucherId: 'sent_300',
        payeeId: 'cafe_x',
        amount: 25.0,
        nonce: 2,
        timestamp: 300,
        signature: 'sig_300',
        payerPubkey: 'customer_pubkey',
      );

      // 3. Received voucher at t=200
      await dbService.recordReceivedVoucher(
        payload: VoucherPayload(
          payerPublicKey: mockKey,
          payeeId: 'merchant_me',
          amountInCents: 5000,
          nonce: 3,
          timestampSeconds: 200,
        ),
        rawBytes: Uint8List(124),
      );

      final history = await dbService.getAllVouchersHistory();
      expect(history.length, equals(3));

      // Ordered by timestamp DESC: 300 (SENT), 200 (RECEIVED), 100 (RECEIVED)
      expect(history[0]['timestamp'], equals(300));
      expect(history[0]['direction'], equals('SENT'));
      expect(history[0]['amount'], equals(25.0));

      expect(history[1]['timestamp'], equals(200));
      expect(history[1]['direction'], equals('RECEIVED'));
      expect(history[1]['amount'], equals(50.0));

      expect(history[2]['timestamp'], equals(100));
      expect(history[2]['direction'], equals('RECEIVED'));
      expect(history[2]['amount'], equals(10.0));
    });

    test('concurrent calls to database safely share the same connection', () async {
      final futures = List.generate(5, (_) => dbService.database);
      final databases = await Future.wait(futures);

      for (var db in databases) {
        expect(identical(db, databases.first), isTrue);
      }
    });
  });

  group('DatabaseService - Backward Compatibility Tests', () {
    test('initializes wallet_state with default values', () async {
      final balance = await dbService.getWalletBalance();
      expect(balance, equals(0.0));

      final state = await dbService.getWalletState();
      expect(state['id'], equals(1));
      expect(state['offline_balance'], equals(0.0));
      expect(state['last_nonce'], equals(0));
      expect(state['lease_id'], isNull);
    });

    test('updates wallet balance and retrieves updated value', () async {
      await dbService.updateWalletBalance(150.75);
      final balance = await dbService.getWalletBalance();
      expect(balance, equals(150.75));
    });

    test('incrementAndGetNonce atomically increments monotonically', () async {
      final nonce1 = await dbService.incrementAndGetNonce();
      expect(nonce1, equals(1));

      final nonce2 = await dbService.incrementAndGetNonce();
      expect(nonce2, equals(2));

      final nonce3 = await dbService.incrementAndGetNonce();
      expect(nonce3, equals(3));

      final state = await dbService.getWalletState();
      expect(state['last_nonce'], equals(3));
    });

    test('incrementAndGetNonce handles concurrent calls monotonically without duplicates', () async {
      // Run 10 concurrent incrementAndGetNonce operations
      final futures = List.generate(10, (_) => dbService.incrementAndGetNonce());
      final nonces = await Future.wait(futures);

      // Verify that all 10 nonces are unique and strictly monotonic
      expect(nonces.toSet().length, equals(10));
      final sorted = List<int>.from(nonces)..sort();
      expect(sorted, equals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
    });

    test('deductBalance decrements balance without modifying nonce', () async {
      await dbService.initWalletState(
        initialBalanceCents: 10000,
        leaseId: 'lease-deduct-test-only',
      );
      final initialNonce = await dbService.incrementAndGetNonce();
      expect(initialNonce, equals(1));

      final success = await dbService.deductBalance(3000);
      expect(success, isTrue);

      final state = await dbService.getWalletState();
      expect(state['offline_balance_cents'], equals(7000));
      expect(state['current_nonce'], equals(1)); // Nonce remains unchanged
    });

    test('applyOfflineLease sets offline_balance_cents, resets current_nonce to 0, and updates active_lease_id', () async {
      // First advance nonce and set balance
      await dbService.applyOfflineLease(
        leaseId: 'initial_lease_001',
        leasedAmount: 100.0,
      );
      await dbService.incrementAndGetNonce();
      await dbService.incrementAndGetNonce();

      final intermediateState = await dbService.getWalletState();
      expect(intermediateState['current_nonce'], equals(2));
      expect(intermediateState['offline_balance_cents'], equals(10000));

      // Now apply new offline lease for 300.0 ETB
      await dbService.applyOfflineLease(
        leaseId: 'lease_bank_vault_300',
        leasedAmount: 300.0,
      );

      final updatedState = await dbService.getWalletState();
      expect(updatedState['offline_balance_cents'], equals(30000));
      expect(updatedState['offline_balance'], equals(300.0));
      expect(updatedState['current_nonce'], equals(0)); // Reset to 0
      expect(updatedState['active_lease_id'], equals('lease_bank_vault_300'));
    });

    test('insertVoucher stores voucher correctly in append-only ledger', () async {
      final mockVoucher = {
        'voucher_id': 'v-001',
        'payer_pubkey': 'payer_pubkey_base64',
        'payee_id': 'user2',
        'amount': 50.0,
        'nonce': 1,
        'timestamp': 123456789,
        'signature': 'signature_base64',
      };

      await dbService.insertVoucher(mockVoucher);

      final unsynced = await dbService.getUnsyncedVouchers();
      expect(unsynced.length, equals(1));
      expect(unsynced.first['voucher_id'], equals('v-001'));
      expect(unsynced.first['payer_pubkey'], equals('payer_pubkey_base64'));
      expect(unsynced.first['payee_id'], equals('user2'));
      expect(unsynced.first['amount'], equals(50.0));
      expect(unsynced.first['nonce'], equals(1));
      expect(unsynced.first['is_synced'], equals(0));
    });

    test('insertVoucher rejects duplicate voucher_id', () async {
      final mockVoucher = {
        'voucher_id': 'v-duplicate',
        'payer_pubkey': 'payer_pubkey_base64',
        'payee_id': 'user2',
        'amount': 50.0,
        'nonce': 1,
        'timestamp': 123456789,
        'signature': 'signature_base64',
      };

      await dbService.insertVoucher(mockVoucher);

      // Attempting to insert the exact same voucher_id must throw
      expect(
        () => dbService.insertVoucher(mockVoucher),
        throwsA(isA<StateError>()),
      );
    });

    test('markVouchersSynced marks specified vouchers as synced (map version)', () async {
      final v1 = {
        'voucher_id': 'v-sync-1',
        'payer_pubkey': 'payer1',
        'payee_id': 'payee1',
        'amount': 10.0,
        'nonce': 1,
        'timestamp': 1000,
        'signature': 'sig1',
      };
      final v2 = {
        'voucher_id': 'v-sync-2',
        'payer_pubkey': 'payer2',
        'payee_id': 'payee2',
        'amount': 20.0,
        'nonce': 2,
        'timestamp': 2000,
        'signature': 'sig2',
      };

      await dbService.insertVoucher(v1);
      await dbService.insertVoucher(v2);

      final initialUnsynced = await dbService.getUnsyncedVouchers();
      expect(initialUnsynced.length, equals(2));

      // Mark only v1 as synced
      final updatedCount = await dbService.markVouchersSynced(['v-sync-1']);
      expect(updatedCount, equals(1));

      final remainingUnsynced = await dbService.getUnsyncedVouchers();
      expect(remainingUnsynced.length, equals(1));
      expect(remainingUnsynced.first['voucher_id'], equals('v-sync-2'));

      // Mark v2 as synced
      await dbService.markVouchersSynced(['v-sync-2']);
      final finalUnsynced = await dbService.getUnsyncedVouchers();
      expect(finalUnsynced, isEmpty);
    });

    test('updateLeaseId updates lease_id in wallet_state', () async {
      await dbService.updateLeaseId('lease-abc-123');
      final state = await dbService.getWalletState();
      expect(state['lease_id'], equals('lease-abc-123'));

      await dbService.updateLeaseId(null);
      final clearedState = await dbService.getWalletState();
      expect(clearedState['lease_id'], isNull);
    });
  });
}
