import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_learning/services/crypto_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('CryptoService - Key Management & Persistence (Rule 1)', () {
    test('generates new keypair on first run and persists seed under offpay_private_seed', () async {
      final storageMap = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(storageMap);

      final cryptoService = CryptoService();
      final keyPair = await cryptoService.getOrCreateKeyPair();
      expect(keyPair, isNotNull);

      // Verify that the seed is stored in secure storage under 'offpay_private_seed'
      expect(storageMap.containsKey(CryptoService.privateKeyStorageKey), isTrue);
      final storedSeed = storageMap[CryptoService.privateKeyStorageKey];
      expect(storedSeed, isNotNull);
      expect(base64Decode(storedSeed!).length, equals(32));
    });

    test('reconstructs keypair from existing 32-byte seed in secure storage', () async {
      // Pre-seed mock storage with a fixed 32-byte seed
      final fixedSeed = Uint8List(32)..fillRange(0, 32, 7);
      final storageMap = <String, String>{
        CryptoService.privateKeyStorageKey: base64Encode(fixedSeed),
      };
      FlutterSecureStorage.setMockInitialValues(storageMap);

      final cryptoService = CryptoService();
      final rawPubKey = await cryptoService.getPublicKeyRaw();
      expect(rawPubKey.length, equals(32));

      // Second instance should reconstruct identical keypair without overwriting seed
      final secondService = CryptoService();
      final secondPubKey = await secondService.getPublicKeyRaw();
      expect(secondPubKey, equals(rawPubKey));
    });

    test('getPublicKeyRaw returns raw 32 bytes of Ed25519 public key', () async {
      final cryptoService = CryptoService();
      final pubKeyRaw = await cryptoService.getPublicKeyRaw();

      expect(pubKeyRaw, isA<Uint8List>());
      expect(pubKeyRaw.length, equals(32));
    });

    test('persists keypair across service instances (Rule 1: generate once on setup)', () async {
      final storageMap = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(storageMap);

      final service1 = CryptoService();
      final pubKey1 = await service1.getPublicKeyRaw();

      // Second instance mimicking app restart
      final service2 = CryptoService();
      final pubKey2 = await service2.getPublicKeyRaw();

      expect(pubKey1, equals(pubKey2));
    });
  });

  group('CryptoService - Binary Packing & Signing (Rule 4 < 150 bytes)', () {
    test('serializeForSigning produces deterministic 60-byte binary payload', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: 'merchant_01',
        amountInCents: 5000, // 50.00 ETB
        nonce: 42,
        timestampSeconds: 1712345678,
      );

      final serialized1 = cryptoService.serializeForSigning(payload);
      final serialized2 = cryptoService.serializeForSigning(payload);

      expect(serialized1.length, equals(60));
      expect(serialized1, equals(serialized2));
    });

    test('packFullVoucher produces payload strictly <= 124 bytes and < 150 bytes (Rule 4)', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: '1234567890123456', // max 16 bytes UTF-8
        amountInCents: 125000,
        nonce: 100,
        timestampSeconds: 1712345678,
      );

      final signature = await cryptoService.signVoucher(payload);
      expect(signature.length, equals(64));

      final packedBytes = await cryptoService.packFullVoucher(payload, signature);

      // Assert size constraints
      expect(packedBytes.length, lessThan(150), reason: 'Rule 4: strictly < 150 bytes');
      expect(packedBytes.length, lessThanOrEqualTo(124), reason: 'Must be <= 124 bytes');
      expect(packedBytes.length, equals(124));
    });

    test('valid packed voucher passes verifyVoucher successfully', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: 'cafe_mercato',
        amountInCents: 2500, // 25.00 ETB
        nonce: 1,
        timestampSeconds: 1712345678,
      );

      final signature = await cryptoService.signVoucher(payload);
      final packedVoucher = await cryptoService.packFullVoucher(payload, signature);

      final isValid = await cryptoService.verifyVoucher(packedVoucher);
      expect(isValid, isTrue);

      // Unpack and verify roundtrip data integrity
      final (unpackedPayload, unpackedSig) = CryptoService.unpackFullVoucher(packedVoucher);
      expect(unpackedPayload.payerPublicKey, equals(payerPubkey));
      expect(unpackedPayload.payeeId, equals('cafe_mercato'));
      expect(unpackedPayload.amountInCents, equals(2500));
      expect(unpackedPayload.nonce, equals(1));
      expect(unpackedPayload.timestampSeconds, equals(1712345678));
      expect(unpackedSig, equals(signature));
    });

    test('altering amount byte in packed voucher causes verifyVoucher to return false', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: 'store_addis',
        amountInCents: 5000,
        nonce: 1,
        timestampSeconds: 1712345678,
      );

      final signature = await cryptoService.signVoucher(payload);
      final packedVoucher = await cryptoService.packFullVoucher(payload, signature);

      // Byte 48 is the most significant byte of amountInCents
      final tampered = Uint8List.fromList(packedVoucher);
      tampered[48] ^= 0x01;

      final isValid = await cryptoService.verifyVoucher(tampered);
      expect(isValid, isFalse);
    });

    test('altering nonce byte in packed voucher causes verifyVoucher to return false', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: 'store_addis',
        amountInCents: 5000,
        nonce: 1,
        timestampSeconds: 1712345678,
      );

      final signature = await cryptoService.signVoucher(payload);
      final packedVoucher = await cryptoService.packFullVoucher(payload, signature);

      // Byte 55 is the least significant byte of nonce
      final tampered = Uint8List.fromList(packedVoucher);
      tampered[55] ^= 0x01;

      final isValid = await cryptoService.verifyVoucher(tampered);
      expect(isValid, isFalse);
    });

    test('altering timestamp, payeeId, pubkey, or signature bytes fails verification', () async {
      final cryptoService = CryptoService();
      final payerPubkey = await cryptoService.getPublicKeyRaw();

      final payload = VoucherPayload(
        payerPublicKey: payerPubkey,
        payeeId: 'merchant',
        amountInCents: 1000,
        nonce: 5,
        timestampSeconds: 1712345678,
      );

      final signature = await cryptoService.signVoucher(payload);
      final packed = await cryptoService.packFullVoucher(payload, signature);

      // Alter payeeId (byte 32)
      final tamperedPayee = Uint8List.fromList(packed)..[32] ^= 0xFF;
      expect(await cryptoService.verifyVoucher(tamperedPayee), isFalse);

      // Alter payerPublicKey (byte 0)
      final tamperedPubkey = Uint8List.fromList(packed)..[0] ^= 0x01;
      expect(await cryptoService.verifyVoucher(tamperedPubkey), isFalse);

      // Alter timestamp (byte 59)
      final tamperedTimestamp = Uint8List.fromList(packed)..[59] ^= 0x01;
      expect(await cryptoService.verifyVoucher(tamperedTimestamp), isFalse);

      // Alter signature byte (byte 60)
      final tamperedSig = Uint8List.fromList(packed)..[60] ^= 0xFF;
      expect(await cryptoService.verifyVoucher(tamperedSig), isFalse);

      // Malformed truncated or extended payload length
      expect(await cryptoService.verifyVoucher(packed.sublist(0, 100)), isFalse);
      expect(await cryptoService.verifyVoucher(Uint8List.fromList([...packed, 0])), isFalse);
    });

    test('validates VoucherPayload constructor constraints', () async {
      final cryptoService = CryptoService();
      final validPubkey = await cryptoService.getPublicKeyRaw();

      // Invalid pubkey length
      expect(
        () => VoucherPayload(
          payerPublicKey: Uint8List(31),
          payeeId: 'valid',
          amountInCents: 100,
          nonce: 1,
          timestampSeconds: 123456,
        ),
        throwsArgumentError,
      );

      // Payee ID exceeding 16 bytes UTF-8
      expect(
        () => VoucherPayload(
          payerPublicKey: validPubkey,
          payeeId: '12345678901234567', // 17 bytes
          amountInCents: 100,
          nonce: 1,
          timestampSeconds: 123456,
        ),
        throwsArgumentError,
      );

      // Negative amount or nonce
      expect(
        () => VoucherPayload(
          payerPublicKey: validPubkey,
          payeeId: 'valid',
          amountInCents: -1,
          nonce: 1,
          timestampSeconds: 123456,
        ),
        throwsRangeError,
      );
    });
  });

  group('CryptoService - Backward Compatibility (JSON Payload API)', () {
    test('signs a mock payment voucher and verifies successfully', () async {
      final cryptoService = CryptoService();

      final mockVoucher = {
        'payer': 'user1',
        'payee': 'user2',
        'amount': 50,
        'nonce': 1,
        'timestamp': 123456,
      };

      final publicKeyBase64 = await cryptoService.getPublicKeyBase64();
      expect(publicKeyBase64, isNotEmpty);
      expect(base64Decode(publicKeyBase64).length, equals(32));

      final signatureBase64 = await cryptoService.signPayload(mockVoucher);
      expect(signatureBase64, isNotEmpty);
      expect(base64Decode(signatureBase64).length, equals(64));

      final isValid = await cryptoService.verifySignature(
        payload: mockVoucher,
        signatureBase64: signatureBase64,
        publicKeyBase64: publicKeyBase64,
      );

      expect(isValid, isTrue);
    });

    test('tampering with the amount in JSON payload fails verification', () async {
      final cryptoService = CryptoService();

      final originalVoucher = {
        'payer': 'user1',
        'payee': 'user2',
        'amount': 50,
        'nonce': 1,
        'timestamp': 123456,
      };

      final publicKeyBase64 = await cryptoService.getPublicKeyBase64();
      final signatureBase64 = await cryptoService.signPayload(originalVoucher);

      final tamperedVoucher = {
        'payer': 'user1',
        'payee': 'user2',
        'amount': 500,
        'nonce': 1,
        'timestamp': 123456,
      };

      final isValid = await cryptoService.verifySignature(
        payload: tamperedVoucher,
        signatureBase64: signatureBase64,
        publicKeyBase64: publicKeyBase64,
      );

      expect(isValid, isFalse);
    });

    test('JSON signing is deterministic regardless of map key ordering', () async {
      final cryptoService = CryptoService();

      final voucher1 = {
        'payer': 'user1',
        'payee': 'user2',
        'amount': 50,
        'nonce': 1,
        'timestamp': 123456,
      };

      final voucher2 = {
        'timestamp': 123456,
        'amount': 50,
        'payee': 'user2',
        'nonce': 1,
        'payer': 'user1',
      };

      final publicKeyBase64 = await cryptoService.getPublicKeyBase64();
      final signatureBase64 = await cryptoService.signPayload(voucher1);

      final isValid = await cryptoService.verifySignature(
        payload: voucher2,
        signatureBase64: signatureBase64,
        publicKeyBase64: publicKeyBase64,
      );

      expect(isValid, isTrue);
    });
  });
}
