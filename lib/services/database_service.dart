import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'crypto_service.dart';

/// Local database service managing the append-only received voucher ledger
/// and offline wallet state (balance and monotonic nonces) using SQLite.
///
/// Adheres strictly to OffPay (AirBirr) guidelines:
/// - Table `vouchers`: Append-only received voucher ledger with replay prevention.
/// - Table `wallet_state`: Atomic balance deductions and monotonic nonce tracking.
/// - Mathematical signature verification using [CryptoService].
class DatabaseService {
  static const String databaseName = 'airbirr_offline.db';
  static const int databaseVersion = 1;

  /// Default initial test balance: 1,000,000.00 ETB (100,000,000 cents)
  static const int defaultInitialBalanceCents = 100000000;
  static const String defaultInitialLeaseId = 'lease_init_1m';

  final Database? _dbInstance;
  final String? customDbPath;
  final CryptoService? cryptoService;

  Database? _database;
  Completer<Database>? _dbOpenCompleter;

  DatabaseService({
    Database? database,
    this.customDbPath,
    this.cryptoService,
  }) : _dbInstance = database;

  CryptoService get activeCryptoService => cryptoService ?? CryptoService();

  /// Returns the underlying SQLite [Database] connection safely as a singleton.
  ///
  /// Prevents race conditions during concurrent initialization.
  Future<Database> get database async {
    final instance = _dbInstance;
    if (instance != null) {
      return instance;
    }
    if (_database != null && _database!.isOpen) {
      return _database!;
    }
    if (_dbOpenCompleter != null) {
      return await _dbOpenCompleter!.future;
    }

    final completer = Completer<Database>();
    _dbOpenCompleter = completer;

    try {
      final db = await _initDatabase();
      _database = db;
      completer.complete(db);
      return db;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _dbOpenCompleter = null;
    }
  }

  /// Resolves the absolute database file path using [path_provider], [path], and [sqflite].
  Future<String> getDatabasePath() async {
    if (customDbPath != null) {
      return customDbPath!;
    }
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      return p.join(appDocDir.path, databaseName);
    } catch (_) {
      final databasesPath = await getDatabasesPath();
      return p.join(databasesPath, databaseName);
    }
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasePath();
    final db = await openDatabase(
      dbPath,
      version: databaseVersion,
      onCreate: _onCreate,
    );
    await _ensureDirectionColumn(db);
    await _ensureWalletProfileColumns(db);
    return db;
  }

  Future<void> _ensureDirectionColumn(Database db) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info(vouchers)');
      final hasDirection = info.any((col) => col['name'] == 'direction');
      if (!hasDirection) {
        await db.execute("ALTER TABLE vouchers ADD COLUMN direction TEXT DEFAULT 'RECEIVED'");
      }
      final hasType = info.any((col) => col['name'] == 'type');
      if (!hasType) {
        await db.execute("ALTER TABLE vouchers ADD COLUMN type TEXT DEFAULT 'RECEIVED'");
      }
    } catch (_) {}
  }

  Future<void> _ensureWalletProfileColumns(Database db) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info(wallet_state)');
      final hasAccountId = info.any((col) => col['name'] == 'account_id');
      if (!hasAccountId) {
        await db.execute('ALTER TABLE wallet_state ADD COLUMN account_id TEXT');
      }
      final hasDisplayName = info.any((col) => col['name'] == 'display_name');
      if (!hasDisplayName) {
        await db.execute('ALTER TABLE wallet_state ADD COLUMN display_name TEXT');
      }
      final hasIsMerchant = info.any((col) => col['name'] == 'is_merchant');
      if (!hasIsMerchant) {
        await db.execute('ALTER TABLE wallet_state ADD COLUMN is_merchant INTEGER DEFAULT 0');
      }
      final hasIsRegistered = info.any((col) => col['name'] == 'is_registered');
      if (!hasIsRegistered) {
        await db.execute('ALTER TABLE wallet_state ADD COLUMN is_registered INTEGER DEFAULT 0');
      }
    } catch (_) {}
  }

  Future<void> _onCreate(Database db, int version) async {
    // Append-only received & sent vouchers ledger table
    await db.execute('''
      CREATE TABLE vouchers (
        voucher_id TEXT PRIMARY KEY,
        payer_pubkey TEXT NOT NULL,
        payee_id TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        nonce INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        raw_bytes BLOB NOT NULL,
        is_synced INTEGER DEFAULT 0,
        type TEXT DEFAULT 'RECEIVED',
        direction TEXT DEFAULT 'RECEIVED'
      )
    ''');

    // Local balances and counters singleton table
    await db.execute('''
      CREATE TABLE wallet_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        offline_balance_cents INTEGER DEFAULT 0,
        current_nonce INTEGER DEFAULT 0,
        active_lease_id TEXT,
        account_id TEXT,
        display_name TEXT,
        is_merchant INTEGER DEFAULT 0,
        is_registered INTEGER DEFAULT 0
      )
    ''');

    await _ensureWalletStateRow(db);
  }

  Future<void> _ensureWalletStateRow(DatabaseExecutor executor) async {
    await executor.insert(
      'wallet_state',
      {
        'id': 1,
        'offline_balance_cents': 0,
        'current_nonce': 0,
        'active_lease_id': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ===========================================================================
  // USER PROFILE & REGISTRATION
  // ===========================================================================

  /// Persists registered user profile into the SQLite wallet state.
  Future<void> saveUserProfile({
    required String accountId,
    required String displayName,
    bool isMerchant = false,
  }) async {
    final db = await database;
    await _ensureWalletStateRow(db);
    await db.update(
      'wallet_state',
      {
        'account_id': accountId,
        'display_name': displayName,
        'is_merchant': isMerchant ? 1 : 0,
        'is_registered': 1,
      },
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  /// Retrieves user profile, or null if wallet has not been registered yet.
  Future<Map<String, dynamic>?> getUserProfile() async {
    final db = await database;
    final results = await db.query(
      'wallet_state',
      columns: ['account_id', 'display_name', 'is_merchant', 'is_registered'],
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (results.isEmpty) return null;
    final row = results.first;
    final accountId = row['account_id'] as String?;
    if (accountId == null || accountId.trim().isEmpty) {
      return null;
    }
    return {
      'account_id': accountId,
      'display_name': (row['display_name'] as String?) ?? accountId,
      'is_merchant': (row['is_merchant'] as num?)?.toInt() == 1,
      'is_registered': true,
    };
  }

  /// Returns true if account_id is not null and not empty.
  Future<bool> isUserRegistered() async {
    final db = await database;
    final results = await db.query(
      'wallet_state',
      columns: ['account_id'],
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (results.isEmpty) return false;
    final accountId = results.first['account_id'] as String?;
    return accountId != null && accountId.trim().isNotEmpty;
  }

  /// Returns true if this device wallet is registered. Alias for [isUserRegistered].
  Future<bool> isWalletRegistered() async => isUserRegistered();

  /// Clears stored user profile (e.g., for wallet reset / log out).
  Future<void> clearUserProfile() async {
    final db = await database;
    await db.update(
      'wallet_state',
      {
        'account_id': null,
        'display_name': null,
        'is_merchant': 0,
        'is_registered': 0,
      },
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  // ===========================================================================
  // 1. CORE ACCOUNTING METHODS
  // ===========================================================================

  /// Applies an offline spending lease from the Central Bank into the local wallet state.
  ///
  /// Updates `wallet_state` table:
  /// - Sets `offline_balance_cents` = (leasedAmount * 100).toInt()
  /// - Resets `current_nonce` = 0
  /// - Sets `active_lease_id` = leaseId
  /// Runs atomically inside a SQLite transaction.
  Future<void> applyOfflineLease({
    required String leaseId,
    required double leasedAmount,
  }) async {
    final balanceCents = (leasedAmount * 100).toInt();
    if (balanceCents < 0) {
      throw ArgumentError('leasedAmount cannot be negative: $leasedAmount');
    }
    final db = await database;
    await db.transaction((txn) async {
      await _ensureWalletStateRow(txn);
      await txn.update(
        'wallet_state',
        {
          'offline_balance_cents': balanceCents,
          'current_nonce': 0,
          'active_lease_id': leaseId,
        },
        where: 'id = ?',
        whereArgs: [1],
      );
    });
  }

  /// Seeds or resets the local wallet state upon receiving an offline lease.
  Future<void> initWalletState({
    required int initialBalanceCents,
    required String leaseId,
  }) async {
    await applyOfflineLease(
      leaseId: leaseId,
      leasedAmount: initialBalanceCents / 100.0,
    );
  }

  /// Returns current balance (in cents) and the next expected nonce.
  Future<Map<String, dynamic>> getWalletState() async {
    final db = await database;
    final results = await db.query(
      'wallet_state',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );

    if (results.isNotEmpty) {
      final row = results.first;
      final balanceCents = (row['offline_balance_cents'] as num?)?.toInt() ?? 0;
      final currentNonce = (row['current_nonce'] as num?)?.toInt() ?? 0;
      final activeLeaseId = row['active_lease_id'] as String?;

      return {
        'id': 1,
        'offline_balance_cents': balanceCents,
        'balance_cents': balanceCents,
        'current_nonce': currentNonce,
        'next_nonce': currentNonce + 1,
        'expected_nonce': currentNonce + 1,
        'active_lease_id': activeLeaseId,
        // Backward-compatibility keys
        'offline_balance': balanceCents / 100.0,
        'last_nonce': currentNonce,
        'lease_id': activeLeaseId,
      };
    }

    await _ensureWalletStateRow(db);
    return {
      'id': 1,
      'offline_balance_cents': 0,
      'balance_cents': 0,
      'current_nonce': 0,
      'next_nonce': 1,
      'expected_nonce': 1,
      'active_lease_id': null,
      'offline_balance': 0.0,
      'last_nonce': 0,
      'lease_id': null,
    };
  }

  /// Uses an atomic SQLite transaction (`db.transaction`):
  /// - Checks if current balance >= amountCents.
  /// - If sufficient, decrements balance, increments nonce by 1, and returns true.
  /// - If insufficient, rolls back and returns false.
  Future<bool> deductBalanceAndIncrementNonce(int amountCents) async {
    if (amountCents < 0) {
      throw ArgumentError('amountCents cannot be negative: $amountCents');
    }
    final db = await database;
    return await db.transaction<bool>((txn) async {
      await _ensureWalletStateRow(txn);
      final rows = await txn.query(
        'wallet_state',
        columns: ['offline_balance_cents', 'current_nonce'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );

      if (rows.isEmpty) {
        return false;
      }

      final currentBalance = (rows.first['offline_balance_cents'] as num?)?.toInt() ?? 0;
      if (currentBalance < amountCents) {
        // Insufficient funds: transaction completes without updating balance or nonce
        return false;
      }

      final count = await txn.rawUpdate(
        '''
        UPDATE wallet_state
        SET offline_balance_cents = offline_balance_cents - ?,
            current_nonce = current_nonce + 1
        WHERE id = ? AND offline_balance_cents >= ?
        ''',
        [amountCents, 1, amountCents],
      );

      return count > 0;
    });
  }

  /// Uses an atomic SQLite transaction (`db.transaction`):
  /// - Checks if current balance >= amountCents.
  /// - If sufficient, decrements balance without modifying nonce, and returns true.
  /// - If insufficient, rolls back and returns false.
  Future<bool> deductBalance(int amountCents) async {
    if (amountCents < 0) {
      throw ArgumentError('amountCents cannot be negative: $amountCents');
    }
    final db = await database;
    return await db.transaction<bool>((txn) async {
      await _ensureWalletStateRow(txn);
      final rows = await txn.query(
        'wallet_state',
        columns: ['offline_balance_cents'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );

      if (rows.isEmpty) {
        return false;
      }

      final currentBalance = (rows.first['offline_balance_cents'] as num?)?.toInt() ?? 0;
      if (currentBalance < amountCents) {
        return false;
      }

      final count = await txn.rawUpdate(
        '''
        UPDATE wallet_state
        SET offline_balance_cents = offline_balance_cents - ?
        WHERE id = ? AND offline_balance_cents >= ?
        ''',
        [amountCents, 1, amountCents],
      );

      return count > 0;
    });
  }

  // ===========================================================================
  // 2. VOUCHER LOGGING METHODS
  // ===========================================================================

  /// Derives a deterministic unique voucher ID from payer public key and nonce (nonce+payer).
  static String deriveVoucherId({
    required Uint8List payerPublicKey,
    required int nonce,
  }) {
    final payerBase64 = base64Encode(payerPublicKey);
    return '${payerBase64}_$nonce';
  }

  /// Inserts the verified voucher into `vouchers`.
  ///
  /// Returns `false` or throws if `voucher_id` already exists (replay prevention).
  /// Parameterized queries prevent SQL injection.
  Future<bool> recordReceivedVoucher({
    VoucherPayload? payload,
    Uint8List? rawBytes,
    String? voucherId,
    String? payerPubkey,
    String? payeeId,
    double? amount,
    int? nonce,
    int? timestamp,
    String? signature,
    bool verifySignature = false,
  }) async {
    final Uint8List raw = rawBytes ??
        (signature != null
            ? Uint8List.fromList(utf8.encode(signature))
            : Uint8List(0));

    if (verifySignature && raw.isNotEmpty) {
      final isValid = await activeCryptoService.verifyVoucher(raw);
      if (!isValid) {
        return false;
      }
    }

    final db = await database;
    final String vId;
    final String payer;
    final String payee;
    final int amountCents;
    final int n;
    final int ts;

    if (payload != null) {
      vId = voucherId ??
          deriveVoucherId(
            payerPublicKey: payload.payerPublicKey,
            nonce: payload.nonce,
          );
      payer = base64Encode(payload.payerPublicKey);
      payee = payload.payeeId;
      amountCents = payload.amountInCents;
      n = payload.nonce;
      ts = payload.timestampSeconds;
    } else {
      vId = voucherId ?? '';
      payer = payerPubkey ?? '';
      payee = payeeId ?? '';
      amountCents = ((amount ?? 0) * 100).round();
      n = nonce ?? 0;
      ts = timestamp ?? 0;
    }

    if (vId.isEmpty) {
      throw ArgumentError('voucherId cannot be empty');
    }

    // Replay prevention: check if voucher_id already exists in ledger
    final existing = await db.query(
      'vouchers',
      columns: ['voucher_id'],
      where: 'voucher_id = ?',
      whereArgs: [vId],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      return false;
    }

    try {
      final rowsAffected = await db.insert(
        'vouchers',
        {
          'voucher_id': vId,
          'payer_pubkey': payer,
          'payee_id': payee,
          'amount_cents': amountCents,
          'nonce': n,
          'timestamp': ts,
          'raw_bytes': raw,
          'is_synced': 0,
          'type': 'RECEIVED',
          'direction': 'RECEIVED',
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return rowsAffected > 0;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return false;
      }
      rethrow;
    }
  }

  /// Records an outgoing voucher sent by this wallet (payer).
  ///
  /// Adds a permanent outgoing receipt tracking payee, amount, nonce, timestamp,
  /// and cryptographic signature with type = 'SENT'.
  Future<bool> recordSentVoucher({
    required String voucherId,
    required String payerPubkey,
    required String payeeId,
    required double amount,
    required int nonce,
    required int timestamp,
    required String signature,
    Uint8List? rawBytes,
  }) async {
    final db = await database;
    final payer = payerPubkey.isNotEmpty
        ? payerPubkey
        : await activeCryptoService.getPublicKeyBase64();
    final amountCents = (amount * 100).round();
    final raw = rawBytes ?? Uint8List.fromList(utf8.encode(signature));

    // Replay prevention: check if voucher_id already exists in ledger
    final existing = await db.query(
      'vouchers',
      columns: ['voucher_id'],
      where: 'voucher_id = ?',
      whereArgs: [voucherId],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      return false;
    }

    try {
      final rowsAffected = await db.insert(
        'vouchers',
        {
          'voucher_id': voucherId,
          'payer_pubkey': payer,
          'payee_id': payeeId,
          'amount_cents': amountCents,
          'nonce': nonce,
          'timestamp': timestamp,
          'raw_bytes': raw,
          'is_synced': 0,
          'type': 'SENT',
          'direction': 'SENT',
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return rowsAffected > 0;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return false;
      }
      rethrow;
    }
  }

  /// Returns all records where `is_synced = 0`.
  Future<List<Map<String, dynamic>>> getUnsyncedVouchers() async {
    final db = await database;
    final results = await db.query(
      'vouchers',
      where: 'is_synced = ?',
      whereArgs: [0],
      orderBy: 'timestamp ASC, nonce ASC',
    );
    return results.map(_formatVoucherRow).toList();
  }

  /// Updates `is_synced = 1` for the given IDs once reconciled with the central backend.
  Future<int> markVouchersSynced(List<String> voucherIds) async {
    if (voucherIds.isEmpty) return 0;
    final db = await database;
    final placeholders = List.filled(voucherIds.length, '?').join(',');
    return await db.update(
      'vouchers',
      {'is_synced': 1},
      where: 'voucher_id IN ($placeholders)',
      whereArgs: voucherIds,
    );
  }

  /// Returns all transactions ordered by timestamp DESC for the transaction history screen.
  Future<List<Map<String, dynamic>>> getAllVouchersHistory() async {
    final db = await database;
    final results = await db.query(
      'vouchers',
      orderBy: 'timestamp DESC',
    );
    return results.map(_formatVoucherRow).toList();
  }

  // ===========================================================================
  // 3. BACKWARD COMPATIBILITY & HELPER METHODS
  // ===========================================================================

  /// Inserts a voucher map into the append-only ledger.
  ///
  /// Rejects duplicate `voucher_id` by throwing a [StateError].
  Future<void> insertVoucher(Map<String, dynamic> voucher) async {
    final db = await database;
    final voucherId = (voucher['voucher_id'] ?? voucher['id'])?.toString();
    if (voucherId == null || voucherId.isEmpty) {
      throw ArgumentError('voucher_id cannot be null or empty.');
    }

    final existing = await db.query(
      'vouchers',
      columns: ['voucher_id'],
      where: 'voucher_id = ?',
      whereArgs: [voucherId],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      throw StateError('Duplicate voucher_id: Voucher "$voucherId" already exists.');
    }

    final rawBytes = voucher['raw_bytes'] is Uint8List
        ? voucher['raw_bytes'] as Uint8List
        : (voucher['signature'] is String
            ? Uint8List.fromList(utf8.encode(voucher['signature'] as String))
            : Uint8List(0));

    final int amountCents;
    if (voucher['amount_cents'] != null) {
      amountCents = (voucher['amount_cents'] as num).toInt();
    } else if (voucher['amount'] != null) {
      amountCents = ((voucher['amount'] as num).toDouble() * 100).round();
    } else {
      amountCents = 0;
    }

    final row = <String, dynamic>{
      'voucher_id': voucherId,
      'payer_pubkey': (voucher['payer_pubkey'] ?? voucher['payer'])?.toString() ?? '',
      'payee_id': (voucher['payee_id'] ?? voucher['payee'])?.toString() ?? '',
      'amount_cents': amountCents,
      'nonce': (voucher['nonce'] as num?)?.toInt() ?? 0,
      'timestamp': (voucher['timestamp'] as num?)?.toInt() ?? 0,
      'raw_bytes': rawBytes,
      'is_synced': (voucher['is_synced'] as num?)?.toInt() ?? 0,
      'type': voucher['type']?.toString() ?? voucher['direction']?.toString() ?? 'RECEIVED',
      'direction': voucher['direction']?.toString() ?? voucher['type']?.toString() ?? 'RECEIVED',
    };

    await db.insert(
      'vouchers',
      row,
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  /// Retrieves the current offline wallet balance in decimal units (e.g. ETB).
  Future<double> getWalletBalance() async {
    final state = await getWalletState();
    return (state['offline_balance'] as num).toDouble();
  }

  /// Updates the offline wallet balance from a decimal value.
  Future<void> updateWalletBalance(double newBalance) async {
    final db = await database;
    await _ensureWalletStateRow(db);
    final cents = (newBalance * 100).round();
    await db.update(
      'wallet_state',
      {'offline_balance_cents': cents},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  /// Atomically increments and returns the next nonce in a database transaction.
  Future<int> incrementAndGetNonce() async {
    final db = await database;
    return await db.transaction<int>((txn) async {
      await _ensureWalletStateRow(txn);
      await txn.rawUpdate(
        'UPDATE wallet_state SET current_nonce = current_nonce + 1 WHERE id = ?',
        [1],
      );
      final result = await txn.query(
        'wallet_state',
        columns: ['current_nonce'],
        where: 'id = ?',
        whereArgs: [1],
        limit: 1,
      );
      return (result.first['current_nonce'] as num).toInt();
    });
  }

  /// Updates the offline lease ID in [wallet_state].
  Future<void> updateLeaseId(String? leaseId) async {
    final db = await database;
    await _ensureWalletStateRow(db);
    await db.update(
      'wallet_state',
      {'active_lease_id': leaseId},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  /// Formats a raw database row from the `vouchers` table into a map containing
  /// both new and backward-compatible fields (e.g. `amount` in double, `signature`).
  Map<String, dynamic> _formatVoucherRow(Map<String, dynamic> row) {
    final map = Map<String, dynamic>.from(row);
    if (map.containsKey('amount_cents')) {
      map['amount'] = (map['amount_cents'] as num).toDouble() / 100.0;
    }
    final rawType = (row['type'] ?? row['direction'] ?? 'RECEIVED').toString();
    map['type'] = rawType;
    map['direction'] = rawType;
    if (map['raw_bytes'] is Uint8List) {
      final bytes = map['raw_bytes'] as Uint8List;
      if (bytes.length == 124) {
        // Packed voucher: 60 bytes serialized payload + 64 bytes signature
        map['signature'] = base64Encode(bytes.sublist(60));
      } else if (bytes.isNotEmpty) {
        try {
          final decoded = utf8.decode(bytes);
          map['signature'] = decoded;
        } catch (_) {
          map['signature'] = base64Encode(bytes);
        }
      }
    }
    return map;
  }

  /// Closes the database connection.
  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
    }
  }
}

/// Riverpod provider for accessing [DatabaseService].
final databaseServiceProvider = Provider<DatabaseService>((ref) {
  final service = DatabaseService();
  ref.onDispose(() {
    service.close();
  });
  return service;
});
