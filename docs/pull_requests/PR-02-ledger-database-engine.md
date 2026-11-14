# PR #2: Add Append-Only SQLite Transaction Ledger & Balance Tracking

**Branch:** `feat/ledger-database-engine` -> `main`  
**Status:** Merged  

## Motivation
Offline peer-to-peer payments require immutable local record-keeping and strict protection against double-spending and replay attacks. Without an online banking authority during transactions, the mobile wallet must maintain an append-only cryptographic ledger and strictly verify all transactions mathematically prior to SQLite persistence.

## Changes Made
- **`DatabaseService` (`lib/services/database_service.dart`)**:
  - Implemented SQLite database layer using `sqflite` with tables:
    - `vouchers`: Append-only received offline payment ledger.
    - `wallet_state`: Monotonic sequence counter and available balance state.
    - `user_profile`: Device registration status and account metadata.
  - Implemented atomic balance deductions and monotonic nonce incrementation.
  - Enforced mathematical Ed25519 signature verification via `CryptoService` before writing any incoming voucher to SQLite.
  - Protected against duplicate nonces, timestamp anomalies, and payload tampering.
- **Phone Utilities (`lib/utils/phone_utils.dart`)**:
  - Implemented canonical Ethiopian phone number normalization (`09...`, `07...`) and international dialing code stripping (`+251`).
- **Unit Tests (`test/database_service_test.dart`)**:
  - 500+ lines of unit tests verifying database lifecycle, concurrent writes, duplicate nonce rejection, and balance auditing.

## How to Test
1. Run database unit tests:
   ```bash
   flutter test test/database_service_test.dart
   ```

## Breaking Changes
None.
