# PR #6: End-to-End Integration Tests, CI Pipeline & Documentation

**Branch:** `test/e2e-and-docs` -> `main`  
**Status:** Merged  

## Motivation
With all core cryptographic, storage, P2P networking, central bank clearinghouse backend, and user interface modules implemented, the project requires end-to-end integration test coverage, continuous integration automation, and comprehensive architectural documentation to ensure production readiness and team maintainability.

## Changes Made
- **End-to-End & Integration Test Suite (`test/`)**:
  - `multi_screen_test.dart`: Validates navigation between bottom navigation tabs, dialog interactions, and UI layout stability.
  - `register_on_bank_test.dart`: Simulates the complete user registration lifecycle, phone number normalization, and bank identity certificate verification.
  - `pin_auth_test.dart`: Validates PIN creation, Argon2 hashing, PIN verification, failed attempt counter, and temporary lockout logic.
  - `widget_test.dart`: Widget-level tests for dashboard balance cards, send/receive tabs, transaction ledger filters, and network status banners.
- **Continuous Integration Workflow (`.github/workflows/ci.yml`)**:
  - Configured GitHub Actions to trigger automatically on pushes and pull requests to `main`.
  - Added parallel jobs:
    - `flutter-test`: Runs `flutter analyze` and `flutter test`.
    - `backend-test`: Runs Python backend integration tests (`python backend/test_backend.py`).
- **Comprehensive Documentation (`README.md`)**:
  - Added architecture flowcharts (`Mermaid`), OffPay security rules, directory map, pull request archive table, and step-by-step developer getting started guides.

## How to Test
1. Run all Flutter automated tests:
   ```bash
   flutter test
   ```
2. Run backend test suite:
   ```bash
   python backend/test_backend.py
   ```

## Breaking Changes
None.
