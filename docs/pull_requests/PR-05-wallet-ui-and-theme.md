# PR #5: Build Offline Wallet UI Screens, Theme & Riverpod Controllers

**Branch:** `feat/wallet-ui-and-theme` -> `main`  
**Status:** Merged  

## Motivation
To deliver a smooth user experience for offline digital payments, the application requires a responsive, high-contrast UI capable of intuitive peer-to-peer discovery, rapid QR code scanning/generation, transparent transaction auditing, and clear connection indicators.

## Changes Made
- **Design System & Theming (`lib/theme/app_theme.dart`)**:
  - Implemented cohesive dark and light Material 3 design systems tailored for fintech.
  - Added primary accents, mint green success badges, warning highlights, and custom card/button styling.
- **Custom UI Components (`lib/widgets/`)**:
  - `NetworkStatusBar`: Real-time banner displaying offline/online connectivity and active Bluetooth/Wi-Fi Direct status.
  - `QrScannerScreen`: High-performance QR scanning with permission handling and camera controls.
  - `ServerSettingsDialog`: In-app clearinghouse endpoint configuration modal.
- **Main Shell Navigation (`lib/screens/main_shell.dart`)**:
  - Custom bottom navigation bar switching seamlessly between Home, Send, Receive, and Ledger tabs.
- **Onboarding & Security Screens (`lib/screens/`)**:
  - `RegisterScreen`: Phone number validation, Ethiopian name input, keypair generation, and bank identity certificate fetching.
  - `PinLoginScreen`: 4-digit PIN authentication with lockout protection and secure keystore verification.
- **Wallet Operation Tabs (`lib/screens/`)**:
  - `HomeTab`: Current balance card, offline lease indicators, quick actions, and recent activity.
  - `SendTab`: Dual-mode payment dispatch (Nearby Connections P2P broadcast or static QR voucher rendering).
  - `ReceiveTab`: Dual-mode payment receiver (Nearby Connections listener or QR scanner with instantaneous cryptographic verification).
  - `LedgerTab`: Searchable, filterable transaction list with status badges and bank sync triggers.
- **Application Bootstrap (`lib/main.dart`)**:
  - `AppGatekeeper` routing cold-start flow based on registration and PIN state.
  - `sqflite_common_ffi` initialization for multi-platform desktop environments.

## How to Test
1. Run widget and screen tests:
   ```bash
   flutter test test/widget_test.dart
   ```
2. Launch on device / desktop:
   ```bash
   flutter run
   ```

## Breaking Changes
None.
