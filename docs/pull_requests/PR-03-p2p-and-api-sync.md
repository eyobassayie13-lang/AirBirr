# PR #3: Implement Offline Peer-to-Peer Transport & Bank Sync API

**Branch:** `feat/p2p-and-api-sync` -> `main`  
**Status:** Merged  

## Motivation
OffPay operates in dual modes:
1. **Offline Mode**: Direct device-to-device voucher exchange between payer and payee over local radio frequencies (Bluetooth Low Energy and Wi-Fi Direct) without mobile data or internet access.
2. **Online Settlement Mode**: Periodic synchronization with the central clearinghouse to register new accounts, verify bank identity keys, and batch-settle accumulated offline vouchers.

## Changes Made
- **`NearbyService` (`lib/services/nearby_service.dart`)**:
  - Implemented peer-to-peer transport using `nearby_connections: ^4.1.0` with `Strategy.P2P_STAR`.
  - Configured service ID `et.airbirr.offpay`.
  - Implemented reactive broadcast streams for discovered devices, connection states (`connecting`, `connected`, `disconnected`), and raw byte payload arrival.
  - Added automatic payload transmission and graceful connection teardown.
- **`ApiService` (`lib/services/api_service.dart`)**:
  - Implemented HTTP REST client for the Central Bank clearinghouse server.
  - Added methods for `/api/v1/bank-public-key`, `/api/v1/accounts/register`, `/api/v1/accounts/{phone}`, `/api/v1/leases/request`, and `/api/v1/vouchers/sync`.
  - Added URL normalization and Riverpod provider wiring.
- **Unit Tests (`test/nearby_service_test.dart`, `test/api_service_test.dart`)**:
  - 500 lines of comprehensive unit tests validating P2P stream emissions, connection state machines, HTTP mock scenarios, and error handling.

## How to Test
1. Run P2P and API unit tests:
   ```bash
   flutter test test/nearby_service_test.dart test/api_service_test.dart
   ```

## Breaking Changes
None.
