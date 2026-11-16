# PR #7: Neon Cloud PostgreSQL Backend, Production Config & Client Polish

**Branch:** `feat/neon-cloud-and-client-polish` -> `main`  
**Status:** In Review  

## Motivation
To transition OffPay (AirBirr) from a local development-only prototype toward a production-grade cloud deployment, the central clearinghouse backend needs cloud database persistence with serverless PostgreSQL (Neon), secure environment configuration without disk-bound master keys, and standard dependency manifests for cloud deployment (e.g., Vercel / Railway / Docker). Additionally, the Flutter client requires production polish—removing dev-only tamper widgets from end-user screens, defaulting API connectivity to the deployed cloud clearinghouse URL with configurable environment overrides, and auto-seeding a generous test balance (1,000,000 ETB) for high-volume offline transaction testing.

## Changes Made
- **Cloud Database & Serverless Architecture (`backend/main.py`)**:
  - Integrated Neon Serverless PostgreSQL support using `psycopg2` with automatic dual-engine fallback to local SQLite when `DATABASE_URL` is omitted.
  - Implemented `PostgresConnectionWrapper` and `PostgresCursorWrapper` for transparent SQL dialect normalization (`?` parameter placeholders mapped to `%s`, SQLite-specific PRAGMAs ignored, automatic schema creation).
  - Added `_load_env_file()` and `_resolve_config_path()` for hierarchical `.env` loading and path resolution.
  - Added support for `BANK_MASTER_SEED` environment variable (32-byte Base64/Hex seed) to eliminate disk-bound key files on ephemeral serverless runtimes.
  - Configurable server host and port via `HOST` and `PORT` environment variables.
- **Backend Packaging & Test Suite (`backend/`)**:
  - Added `backend/requirements.txt`, `backend/.gitignore`, and `backend/.vercelignore`.
  - Expanded test suite in `backend/test_backend.py` from 15 to 18 comprehensive tests, covering `BANK_MASTER_SEED` env var parsing, `PostgresCursorWrapper` query rewriting, and `PostgresConnectionWrapper` transaction commit/rollback semantics.
- **Environment & Cloud Configuration (`.env.example`, `neon.ts`, `package.json`, `.gitignore`)**:
  - Added comprehensive `.env.example` template documenting local, mobile, cloud database, and central clearinghouse settings.
  - Added Neon branching policy configuration (`neon.ts`) and project package manifest.
  - Updated root `.gitignore` to prevent leaking `.env`, `.neon`, or `node_modules/`.
- **Flutter Client Polish & Default API Endpoint (`lib/`)**:
  - Configured `ApiService.defaultServerUrl` to resolve from `--dart-define-from-file=.env` (`OFFPAY_API_URL` or `API_BASE_URL`) with fallback to `https://airbirr-api.vercel.app`.
  - Updated server settings dialog hints and normalization logic.
  - Auto-seeded initial test balance of 1,000,000.00 ETB in `DatabaseService` (`defaultInitialBalanceCents = 100000000`) on account registration and empty wallet loads.
  - Polished user interface screens (`main_shell.dart`, `send_tab.dart`): removed developer test suite action menus and test signature tampering checkboxes from consumer transaction dialogs.
  - Updated `test/api_service_test.dart` to assert the cloud production API URL.

## How to Test
1. **Run Backend Test Suite**:
   ```bash
   backend/venv/bin/python3 backend/test_backend.py
   ```
   All 18 integration tests must pass with exit code 0.
2. **Verify Environment Seed Loading**:
   ```bash
   BANK_MASTER_SEED="MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=" backend/venv/bin/python3 -c "import backend.main as m; m.load_or_generate_bank_key(); print('Bank Pubkey:', m.get_bank_public_key_b64())"
   ```
3. **Run Flutter Tests**:
   ```bash
   flutter test test/api_service_test.dart
   ```

## Breaking Changes
None. SQLite remains the zero-configuration default for local development, and the API maintains 100% backward compatibility with all existing OffPay clients and wire payloads.
