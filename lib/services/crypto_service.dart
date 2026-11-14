import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A binary-packed voucher payload conforming to OffPay guidelines (< 150 bytes).
class VoucherPayload {
  /// 32-byte Ed25519 public key of the payer.
  final Uint8List payerPublicKey;

  /// Merchant or payee identifier (max 16 bytes UTF-8).
  final String payeeId;

  /// Transaction amount in cents (32-bit unsigned integer).
  final int amountInCents;

  /// Monotonically increasing transaction sequence number (32-bit unsigned integer).
  final int nonce;

  /// Unix timestamp in seconds (32-bit unsigned integer).
  final int timestampSeconds;

  VoucherPayload({
    required this.payerPublicKey,
    required this.payeeId,
    required this.amountInCents,
    required this.nonce,
    required this.timestampSeconds,
  }) {
    if (payerPublicKey.length != 32) {
      throw ArgumentError('payerPublicKey must be exactly 32 bytes, got ${payerPublicKey.length}');
    }
    if (utf8.encode(payeeId).length > 16) {
      throw ArgumentError('payeeId must not exceed 16 UTF-8 bytes');
    }
    if (amountInCents < 0 || amountInCents > 0xFFFFFFFF) {
      throw RangeError('amountInCents must be a 32-bit unsigned integer (0..4294967295)');
    }
    if (nonce < 0 || nonce > 0xFFFFFFFF) {
      throw RangeError('nonce must be a 32-bit unsigned integer (0..4294967295)');
    }
    if (timestampSeconds < 0 || timestampSeconds > 0xFFFFFFFF) {
      throw RangeError('timestampSeconds must be a 32-bit unsigned integer (0..4294967295)');
    }
  }

  /// Deserializes a 60-byte payload into a [VoucherPayload].
  factory VoucherPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != 60) {
      throw ArgumentError('Serialized payload must be exactly 60 bytes, got ${bytes.length}');
    }
    final byteData = ByteData.sublistView(bytes);
    final payerPublicKey = Uint8List.fromList(bytes.sublist(0, 32));

    final rawPayee = bytes.sublist(32, 48);
    final nullIdx = rawPayee.indexOf(0);
    final payeeBytes = nullIdx == -1 ? rawPayee : rawPayee.sublist(0, nullIdx);
    final payeeId = utf8.decode(payeeBytes);

    final amountInCents = byteData.getUint32(48, Endian.big);
    final nonce = byteData.getUint32(52, Endian.big);
    final timestampSeconds = byteData.getUint32(56, Endian.big);

    return VoucherPayload(
      payerPublicKey: payerPublicKey,
      payeeId: payeeId,
      amountInCents: amountInCents,
      nonce: nonce,
      timestampSeconds: timestampSeconds,
    );
  }

  Map<String, dynamic> toMap() => {
        'payerPublicKey': payerPublicKey,
        'payeeId': payeeId,
        'amountInCents': amountInCents,
        'nonce': nonce,
        'timestampSeconds': timestampSeconds,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VoucherPayload) return false;
    if (payeeId != other.payeeId ||
        amountInCents != other.amountInCents ||
        nonce != other.nonce ||
        timestampSeconds != other.timestampSeconds ||
        payerPublicKey.length != other.payerPublicKey.length) {
      return false;
    }
    for (int i = 0; i < payerPublicKey.length; i++) {
      if (payerPublicKey[i] != other.payerPublicKey[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(payerPublicKey),
        payeeId,
        amountInCents,
        nonce,
        timestampSeconds,
      );

  @override
  String toString() =>
      'VoucherPayload(payerPublicKey: ${payerPublicKey.length}B, payeeId: $payeeId, amountInCents: $amountInCents, nonce: $nonce, timestampSeconds: $timestampSeconds)';
}

/// Standalone cryptographic service implementing Ed25519 signing and verification,
/// binary packing, and persistent private key seed storage adhering to OffPay guidelines.
class CryptoService {
  final FlutterSecureStorage _secureStorage;
  final Ed25519 _algorithm;

  SimpleKeyPair? _cachedKeyPair;

  /// Secure storage key for persisting the Ed25519 private key seed.
  static const String privateKeyStorageKey = 'offpay_private_seed';
  static const String legacyPrivateKeyStorageKey = 'offpay_ed25519_private_key_seed';

  CryptoService({
    FlutterSecureStorage? secureStorage,
    Ed25519? algorithm,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _algorithm = algorithm ?? Ed25519();

  /// Retrieves an existing Ed25519 keypair from secure storage or generates a new one.
  ///
  /// Adheres to OffPay Rule 1: Keypair is generated once on setup and persisted securely.
  Future<SimpleKeyPair> getOrCreateKeyPair() async {
    if (_cachedKeyPair != null) {
      return _cachedKeyPair!;
    }

    final storedSeed = await _secureStorage.read(key: privateKeyStorageKey) ??
        await _secureStorage.read(key: legacyPrivateKeyStorageKey);

    if (storedSeed != null && storedSeed.isNotEmpty) {
      final seed = _decodeSeed(storedSeed);
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      _cachedKeyPair = keyPair;
      return keyPair;
    }

    // Generate a fresh keypair once on setup and persist the 32-byte seed securely
    final newKeyPair = await _algorithm.newKeyPair();
    final seed = await newKeyPair.extractPrivateKeyBytes();
    await _secureStorage.write(
      key: privateKeyStorageKey,
      value: base64Encode(seed),
    );

    _cachedKeyPair = newKeyPair;
    return newKeyPair;
  }

  /// Clears in-memory cached keypair.
  void clearCache() {
    _cachedKeyPair = null;
  }

  /// Returns the 32 raw bytes of the current user's Ed25519 public key.
  Future<Uint8List> getPublicKeyRaw() async {
    final keyPair = await getOrCreateKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  /// Returns the current user's Ed25519 public key as a Base64 string.
  Future<String> getPublicKeyBase64() async {
    final raw = await getPublicKeyRaw();
    return base64Encode(raw);
  }

  /// Serializes a [VoucherPayload] into deterministic 60-byte binary representation
  /// using [ByteData].
  ///
  /// Layout:
  /// - 0..31: payerPublicKey (32 bytes)
  /// - 32..47: payeeId (16 bytes, UTF-8 padded with 0x00)
  /// - 48..51: amountInCents (uint32, big-endian)
  /// - 52..55: nonce (uint32, big-endian)
  /// - 56..59: timestampSeconds (uint32, big-endian)
  Uint8List serializeForSigning(VoucherPayload payload) {
    if (payload.payerPublicKey.length != 32) {
      throw ArgumentError('payerPublicKey must be exactly 32 bytes');
    }
    final payeeBytes = utf8.encode(payload.payeeId);
    if (payeeBytes.length > 16) {
      throw ArgumentError('payeeId exceeds 16 UTF-8 bytes');
    }

    final data = ByteData(60);
    // 0..31: payerPublicKey
    for (int i = 0; i < 32; i++) {
      data.setUint8(i, payload.payerPublicKey[i]);
    }

    // 32..47: payeeId (padded with 0 to 16 bytes)
    for (int i = 0; i < 16; i++) {
      data.setUint8(32 + i, i < payeeBytes.length ? payeeBytes[i] : 0);
    }

    // 48..51: amountInCents
    data.setUint32(48, payload.amountInCents, Endian.big);

    // 52..55: nonce
    data.setUint32(52, payload.nonce, Endian.big);

    // 56..59: timestampSeconds
    data.setUint32(56, payload.timestampSeconds, Endian.big);

    return Uint8List.fromList(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }

  /// Signs the serialized voucher payload using Ed25519.
  ///
  /// Returns the 64-byte Ed25519 signature.
  Future<Uint8List> signVoucher(VoucherPayload payload, {SimpleKeyPair? keyPair}) async {
    final signer = keyPair ?? await getOrCreateKeyPair();
    final messageBytes = serializeForSigning(payload);
    final signature = await _algorithm.sign(messageBytes, keyPair: signer);
    return Uint8List.fromList(signature.bytes);
  }

  /// Combines the 60-byte payload + 64-byte signature into a single byte array.
  ///
  /// Strictly satisfies Rule 4 (< 150 bytes) and requirement (<= 124 bytes).
  Future<Uint8List> packFullVoucher(VoucherPayload payload, Uint8List signature) async {
    if (signature.length != 64) {
      throw ArgumentError('Signature must be exactly 64 bytes, got ${signature.length}');
    }
    final serializedPayload = serializeForSigning(payload);
    final packed = Uint8List(serializedPayload.length + signature.length);
    packed.setRange(0, serializedPayload.length, serializedPayload);
    packed.setRange(serializedPayload.length, packed.length, signature);

    if (packed.length > 124) {
      throw StateError('Packed voucher exceeds 124 bytes limit: ${packed.length}');
    }
    return packed;
  }

  /// Unpacks the bytes, extracts the public key and signature, and verifies mathematical authenticity.
  ///
  /// Returns `true` if mathematically authentic and untampered, `false` otherwise.
  Future<bool> verifyVoucher(Uint8List packedBytes) async {
    try {
      if (packedBytes.length != 124) {
        return false;
      }

      final payloadBytes = packedBytes.sublist(0, 60);
      final signatureBytes = packedBytes.sublist(60, 124);

      final payload = VoucherPayload.fromBytes(payloadBytes);
      if (payload.payerPublicKey.length != 32) {
        return false;
      }

      final publicKey = SimplePublicKey(
        payload.payerPublicKey,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        signatureBytes,
        publicKey: publicKey,
      );

      return await _algorithm.verify(payloadBytes, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Unpacks a 124-byte packed voucher into its [VoucherPayload] and 64-byte signature.
  static (VoucherPayload, Uint8List) unpackFullVoucher(Uint8List packedBytes) {
    if (packedBytes.length != 124) {
      throw ArgumentError('Packed voucher must be exactly 124 bytes, got ${packedBytes.length}');
    }
    final payloadBytes = Uint8List.sublistView(packedBytes, 0, 60);
    final signatureBytes = Uint8List.sublistView(packedBytes, 60, 124);
    return (VoucherPayload.fromBytes(payloadBytes), signatureBytes);
  }

  /// Serializes a JSON payload into deterministic UTF-8 bytes and signs it using Ed25519.
  ///
  /// Returns the 64-byte Ed25519 signature encoded as a Base64 string.
  Future<String> signPayload(Map<String, dynamic> payload) async {
    final keyPair = await getOrCreateKeyPair();
    final messageBytes = deterministicEncode(payload);
    final signature = await _algorithm.sign(messageBytes, keyPair: keyPair);
    return base64Encode(signature.bytes);
  }

  /// Verifies an Ed25519 signature against a given payload and sender's Base64 public key.
  ///
  /// Returns `true` if mathematically valid, or `false` if invalid/tampered/malformed.
  Future<bool> verifySignature({
    required Map<String, dynamic> payload,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    try {
      final signatureBytes = base64Decode(signatureBase64);
      if (signatureBytes.length != 64) {
        return false;
      }

      final publicKeyBytes = base64Decode(publicKeyBase64);
      if (publicKeyBytes.length != 32) {
        return false;
      }

      final messageBytes = deterministicEncode(payload);
      final publicKey = SimplePublicKey(
        publicKeyBytes,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        signatureBytes,
        publicKey: publicKey,
      );

      return await _algorithm.verify(messageBytes, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Converts a JSON map into deterministic canonical UTF-8 bytes.
  Uint8List deterministicEncode(Map<String, dynamic> payload) {
    final canonicalString = canonicalJson(payload);
    return Uint8List.fromList(utf8.encode(canonicalString));
  }

  /// Produces a canonical JSON string with sorted map keys at all hierarchy levels.
  static String canonicalJson(dynamic object) {
    if (object is Map) {
      final sortedKeys = object.keys.map((k) => k.toString()).toList()..sort();
      final buffer = StringBuffer('{');
      for (var i = 0; i < sortedKeys.length; i++) {
        final key = sortedKeys[i];
        if (i > 0) buffer.write(',');
        buffer.write(jsonEncode(key));
        buffer.write(':');
        buffer.write(canonicalJson(object[key]));
      }
      buffer.write('}');
      return buffer.toString();
    } else if (object is List) {
      final buffer = StringBuffer('[');
      for (var i = 0; i < object.length; i++) {
        if (i > 0) buffer.write(',');
        buffer.write(canonicalJson(object[i]));
      }
      buffer.write(']');
      return buffer.toString();
    } else {
      return jsonEncode(object);
    }
  }

  /// Decodes a 32-byte seed from base64, hex, or raw characters.
  static Uint8List _decodeSeed(String raw) {
    final trimmed = raw.trim();
    try {
      final decoded = base64Decode(trimmed);
      if (decoded.length == 32) return Uint8List.fromList(decoded);
    } catch (_) {}

    if (trimmed.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) {
      final bytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        bytes[i] = int.parse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return bytes;
    }

    if (trimmed.length == 32) {
      return Uint8List.fromList(trimmed.codeUnits);
    }

    throw FormatException('Invalid seed format in secure storage (expected 32-byte seed)');
  }
}

/// Riverpod provider for accessing [CryptoService] across the application.
final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});
