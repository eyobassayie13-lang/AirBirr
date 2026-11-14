import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_learning/services/api_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiService Tests', () {
    test('registerAccount successfully posts to /api/v1/auth/register and returns success map', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/v1/auth/register'));
        expect(request.method, equals('POST'));

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['account_id'], equals('0911000001'));
        expect(body['owner_name'], equals('Abebe'));
        expect(body['is_merchant'], isFalse);

        return http.Response(
          jsonEncode({
            'status': 'success',
            'account_id': '0911000001',
            'owner_name': 'Abebe',
            'public_key': 'pubkey123',
            'online_balance': 1000.0,
            'is_merchant': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final result = await apiService.registerAccount(
        accountId: '0911000001',
        ownerName: 'Abebe',
        publicKey: 'pubkey123',
        isMerchant: false,
      );

      expect(result, isNotNull);
      expect(result!['status'], equals('success'));
      expect(result['account_id'], equals('0911000001'));
    });

    test('registerAccount returns already_registered map when server returns already_registered status', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'status': 'already_registered',
            'account_id': '0911000001',
            'online_balance': 1000.0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final result = await apiService.registerAccount(
        accountId: '0911000001',
        ownerName: 'Abebe',
        publicKey: 'pubkey123',
        isMerchant: false,
      );

      expect(result, isNotNull);
      expect(result!['status'], equals('already_registered'));
      expect(result['account_id'], equals('0911000001'));
    });

    test('registerAccount returns null when server cannot be reached', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection refused');
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final result = await apiService.registerAccount(
        accountId: '0911000001',
        ownerName: 'Abebe',
        publicKey: 'pubkey123',
        isMerchant: false,
      );

      expect(result, isNull);
    });

    test('requestOfflineLease successfully posts to /api/v1/lease/issue and returns certificate', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/v1/lease/issue'));
        expect(request.method, equals('POST'));

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['account_id'], equals('0911000001'));
        expect(body['amount_to_lease'], equals(300.0));
        expect(body['duration_days'], equals(7));

        return http.Response(
          jsonEncode({
            'lease_id': 'lease_123',
            'account_id': '0911000001',
            'amount_leased': 300.0,
            'remaining_online_balance': 700.0,
            'certificate': {
              'lease_id': 'lease_123',
              'payer_pubkey': 'pubkey123',
              'max_allowance': 300.0,
              'expires_at': 1700000000,
              'signature': 'banksig123',
              'issuer_public_key': 'bankpubkey123',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final cert = await apiService.requestOfflineLease(
        accountId: '0911000001',
        amount: 300.0,
      );

      expect(cert, isNotNull);
      expect(cert!['lease_id'], equals('lease_123'));
      expect(cert['max_allowance'], equals(300.0));
      expect(cert['signature'], equals('banksig123'));
    });

    test('uploadBatchVouchers posts to /api/v1/settlement/batch-sync and returns settled IDs', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/v1/settlement/batch-sync'));
        expect(request.method, equals('POST'));

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final vouchers = body['vouchers'] as List<dynamic>;
        expect(vouchers.length, equals(2));
        expect(vouchers[0]['voucher_id'], equals('v1'));
        expect(vouchers[1]['voucher_id'], equals('v2'));

        return http.Response(
          jsonEncode({
            'settled_voucher_ids': ['v1', 'v2'],
            'newly_cleared_count': 2,
            'already_synced_count': 0,
            'rejected_count': 0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final unsynced = [
        {
          'voucher_id': 'v1',
          'payer_pubkey': 'payer1',
          'payee_id': 'merchant1',
          'amount': 50.0,
          'nonce': 1,
          'timestamp': 1700000000,
          'signature': 'sig1',
        },
        {
          'voucher_id': 'v2',
          'payer_pubkey': 'payer1',
          'payee_id': 'merchant1',
          'amount': 75.0,
          'nonce': 2,
          'timestamp': 1700000050,
          'signature': 'sig2',
        },
      ];

      final settledIds = await apiService.uploadBatchVouchers(unsynced);

      expect(settledIds, equals(['v1', 'v2']));
    });

    test('uploadBatchVouchers returns empty list on empty input', () async {
      final mockClient = MockClient((request) async => http.Response('', 200));
      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      final settledIds = await apiService.uploadBatchVouchers([]);
      expect(settledIds, isEmpty);
    });

    test('baseUrl defaults to https://upriver-carrousel-battery.ngrok-free.dev and normalizes trailing slashes', () {
      final defaultService = ApiService();
      expect(defaultService.baseUrl, equals('https://upriver-carrousel-battery.ngrok-free.dev'));

      final slashService = ApiService(baseUrl: 'http://192.168.1.100:8000///');
      expect(slashService.baseUrl, equals('http://192.168.1.100:8000'));
    });

    test('setBaseUrl updates baseUrl and dynamically redirects future HTTP calls', () async {
      String? requestedHost;
      final mockClient = MockClient((request) async {
        requestedHost = request.url.origin;
        return http.Response(jsonEncode({'public_key': 'mock_bank_pubkey'}), 200);
      });

      final apiService = ApiService(baseUrl: 'http://old-host:8000', client: mockClient);
      await apiService.getBankPublicKey();
      expect(requestedHost, equals('http://old-host:8000'));

      apiService.setBaseUrl('http://new-host:9000//');
      expect(apiService.baseUrl, equals('http://new-host:9000'));

      await apiService.getBankPublicKey();
      expect(requestedHost, equals('http://new-host:9000'));
    });

    test('checkHealth returns true when /api/v1/health returns 200', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, equals('/api/v1/health'));
        return http.Response(jsonEncode({'status': 'healthy'}), 200);
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);
      final isHealthy = await apiService.checkHealth();
      expect(isHealthy, isTrue);
    });

    test('checkHealth returns false when /api/v1/health fails or connection errors', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Connection refused');
      });

      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);
      final isHealthy = await apiService.checkHealth();
      expect(isHealthy, isFalse);
    });

    test('checkHealth respects forcedOnlineStatus override', () async {
      final mockClient = MockClient((request) async => http.Response('ok', 200));
      final apiService = ApiService(baseUrl: 'http://test-server:8000', client: mockClient);

      apiService.forcedOnlineStatus = false;
      expect(await apiService.checkHealth(), isFalse);

      apiService.forcedOnlineStatus = true;
      expect(await apiService.checkHealth(), isTrue);
    });
  });
}
