# PR #1: Implement Ed25519 Cryptography & Secure Keystore Engine

**Branch:** `feat/core-crypto-service` -> `main`  
**Status:** Merged  

## Motivation
OffPay requires a zero-trust offline payment architecture where mobile devices can transact without an active internet connection. To guarantee authenticity and non-repudiation, transactions must be signed cryptographically using Ed25519 asymmetric signatures and stored securely in the hardware-backed Android Keystore.

## Changes Made
- **`CryptoService` (`lib/services/crypto_service.dart`)**:
  - Implemented Ed25519 keypair generation using `cryptography: ^2.7.2`.
  - Added secure storage persistence using `flutter_secure_storage` to ensure keypairs are generated once on wallet creation and never regenerated per transaction.
  - Implemented deterministic signing of binary voucher payloads.
  - Implemented mathematical signature verification against the payer's public key.
- **Compact Binary `VoucherPayload`**:
  - Packed 32-byte payer public key, 16-byte payee ID, 32-bit amount, 32-bit monotonic nonce, and 32-bit timestamp into an exact 60-byte binary frame (comfortably below the 150-byte constraint).
- **Developer Tools (`tools/ed25519_keygen.dart`)**:
  - CLI script to generate test seed keys and public/private key pairs.
- **Unit Tests (`test/crypto_service_test.dart`)**:
  - Full suite covering serialization, deserialization, signature validation, tampering rejection, and boundary limits.

## How to Test
1. Run crypto unit tests:
   ```bash
   flutter test test/crypto_service_test.dart
   ```
2. Test key generator:
   ```bash
   dart run tools/ed25519_keygen.dart
   ```

## Breaking Changes
None.
