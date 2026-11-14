# PR #4: Central Bank Verification & Voucher Settlement Backend

**Branch:** `feat/bank-settlement-backend` -> `main`  
**Status:** Merged  

## Motivation
While transactions occur offline between peer devices, eventual settlement requires a trusted central clearinghouse. The backend acts as the Central Bank identity authority: issuing verifiable identity certificates, tracking global account balances, issuing offline spending leases, and settling offline vouchers when devices regain internet connectivity.

## Changes Made
- **Central Clearinghouse (`backend/main.py`)**:
  - Built high-performance FastAPI service with SQLite database (`master_bank.db`).
  - Implemented Ed25519 bank master key generation with seed persistence.
  - Added REST API endpoints:
    - `GET /api/v1/bank-public-key`: Returns bank Ed25519 public key.
    - `POST /api/v1/accounts/register`: Creates account, credits initial balance, and issues signed Bank Identity Certificate.
    - `GET /api/v1/accounts/{phone}`: Account profile, available balance, and ledger history.
    - `POST /api/v1/leases/request`: Deducts on-chain balance and issues offline LeaseCertificate.
    - `POST /api/v1/vouchers/sync`: Batch-processes offline vouchers, checks for double-spending or replay attacks, verifies Ed25519 signatures, and credits payees idempotently.
  - Supports compact binary voucher decoding (< 150 bytes) and JSON payloads.
- **Integration Test Suite (`backend/test_backend.py`)**:
  - 15 comprehensive automated test scenarios testing key persistence, registration, lease issuance, double-spend detection, tampering, and replay prevention.

## How to Test
1. Run backend automated test suite:
   ```bash
   python backend/test_backend.py
   ```
2. Run backend dev server:
   ```bash
   uvicorn backend.main:app --host 0.0.0.0 --port 8000
   ```

## Breaking Changes
None.
