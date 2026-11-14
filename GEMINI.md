# OffPay (AirBirr) - Project Guidelines

## Tech Stack & Constraints
- Platform: Flutter (Dart 3.x), Riverpod for state management.
- Cryptography: `cryptography: ^2.7.2` using Ed25519 asymmetric signatures.
- Secure Storage: `flutter_secure_storage` to persist private keys in Android Keystore.
- Local Database: `sqflite` with an append-only transaction ledger.
- P2P Comm: `nearby_connections: ^4.1.0` (Strategy: P2P_STAR or P2P_POINT_TO_POINT).

## Rules
1. Never generate a new keypair on every transaction. Generate once on wallet setup and persist in secure storage.
2. Vouchers must be signed deterministically using Ed25519.
3. Every incoming transaction must be verified mathematically before writing to SQLite.
4. Keep all payloads under 150 bytes when serialized.