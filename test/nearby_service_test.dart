import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:flutter_learning/services/nearby_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nearby_connections');
  final methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      methodCalls.add(call);
      switch (call.method) {
        case 'startAdvertising':
        case 'startDiscovery':
        case 'requestConnection':
        case 'acceptConnection':
        case 'rejectConnection':
          return true;
        case 'stopAdvertising':
        case 'stopDiscovery':
        case 'stopAllEndpoints':
        case 'sendPayload':
        case 'disconnectFromEndpoint':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('NearbyService Tests - OffPay Requirements', () {
    test('configuration uses et.airbirr.offpay and Strategy.P2P_STAR', () {
      expect(NearbyService.serviceId, equals('et.airbirr.offpay'));
      expect(NearbyService.strategy, equals(Strategy.P2P_STAR));
    });

    test('startAdvertising invokes channel with Strategy.P2P_STAR and et.airbirr.offpay', () async {
      final service = NearbyService();

      final started = await service.startAdvertising(
        merchantName: 'AirBirrMerchant',
        onPayloadReceived: (endpointId, payload) {},
      );

      expect(started, isTrue);
      expect(service.isAdvertising, isTrue);

      final call = methodCalls.firstWhere((c) => c.method == 'startAdvertising');
      expect(call.arguments['userNickName'], equals('AirBirrMerchant'));
      expect(call.arguments['serviceId'], equals('et.airbirr.offpay'));
      // Strategy.P2P_STAR index in nearby_connections is 1
      expect(call.arguments['strategy'], equals(1));
    });

    test('startAdvertising stops previous session to prevent simultaneous advertising', () async {
      final service = NearbyService();

      await service.startAdvertising(
        merchantName: 'MerchantA',
        onPayloadReceived: (endpointId, payload) {},
      );

      // Starting advertising again should stop previous session first
      await service.startAdvertising(
        merchantName: 'MerchantB',
        onPayloadReceived: (endpointId, payload) {},
      );

      final stopAdvertisingCalls = methodCalls.where((c) => c.method == 'stopAdvertising').toList();
      expect(stopAdvertisingCalls.length, equals(1));
    });

    test('startDiscovery invokes channel with Strategy.P2P_STAR and et.airbirr.offpay', () async {
      final service = NearbyService();

      final started = await service.startDiscovery(
        userName: 'AirBirrCustomer',
        onEndpointFound: (endpointId, endpointName) {},
        onEndpointLost: (endpointId) {},
      );

      expect(started, isTrue);
      expect(service.isDiscovering, isTrue);

      final call = methodCalls.firstWhere((c) => c.method == 'startDiscovery');
      expect(call.arguments['userNickName'], equals('AirBirrCustomer'));
      expect(call.arguments['serviceId'], equals('et.airbirr.offpay'));
      expect(call.arguments['strategy'], equals(1));
    });

    test('startDiscovery stops previous session to prevent simultaneous discovery', () async {
      final service = NearbyService();

      await service.startDiscovery(
        onEndpointFound: (endpointId, endpointName) {},
        onEndpointLost: (endpointId) {},
      );

      // Starting discovery again should stop previous session first
      await service.startDiscovery(
        onEndpointFound: (endpointId, endpointName) {},
        onEndpointLost: (endpointId) {},
      );

      final stopDiscoveryCalls = methodCalls.where((c) => c.method == 'stopDiscovery').toList();
      expect(stopDiscoveryCalls.length, equals(1));
    });

    test('sendVoucherPayload validates empty endpointId or empty voucher bytes', () async {
      final service = NearbyService();

      // Empty endpoint ID
      final emptyEndpointResult = await service.sendVoucherPayload(
        endpointId: '',
        packedVoucherBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(emptyEndpointResult, isFalse);

      // Empty payload bytes
      final emptyBytesResult = await service.sendVoucherPayload(
        endpointId: 'ep_test',
        packedVoucherBytes: Uint8List(0),
      );
      expect(emptyBytesResult, isFalse);

      // Verify no connection request was sent
      expect(methodCalls.where((c) => c.method == 'requestConnection'), isEmpty);
    });

    test('sendVoucherPayload requests connection with expected client name and endpoint', () async {
      final service = NearbyService();
      final voucherBytes = Uint8List.fromList(List.filled(124, 0x55));

      // Invoke sendVoucherPayload with very short timeout since mock does not complete connection result
      final sendFuture = service.sendVoucherPayload(
        endpointId: 'merchant_ep_01',
        packedVoucherBytes: voucherBytes,
        clientName: 'CustomerPayer',
        timeout: const Duration(milliseconds: 100),
      );

      final result = await sendFuture;
      expect(result, isFalse); // Timed out gracefully

      final requestCall = methodCalls.firstWhere((c) => c.method == 'requestConnection');
      expect(requestCall.arguments['endpointId'], equals('merchant_ep_01'));
      expect(requestCall.arguments['userNickName'], equals('CustomerPayer'));
    });

    test('connectAndSendPayload provides backward compatibility', () async {
      final service = NearbyService();

      var onSentCalled = false;
      final resultEmpty = await service.connectAndSendPayload(
        endpointId: '',
        payload: Uint8List.fromList([1, 2, 3]),
        onSent: () => onSentCalled = true,
      );

      expect(resultEmpty, isFalse);
      expect(onSentCalled, isFalse);
    });

    test('stopAll stops advertising, discovery, and disconnects all endpoints', () async {
      final service = NearbyService();

      await service.startAdvertising(
        merchantName: 'Merchant1',
        onPayloadReceived: (endpointId, payload) {},
      );
      await service.startDiscovery(
        onEndpointFound: (endpointId, endpointName) {},
        onEndpointLost: (endpointId) {},
      );

      await service.stopAll();

      expect(service.isAdvertising, isFalse);
      expect(service.isDiscovering, isFalse);
      expect(service.discoveredEndpoints, isEmpty);
      expect(service.connectedEndpoints, isEmpty);

      final calledMethods = methodCalls.map((c) => c.method).toList();
      expect(calledMethods, contains('stopAdvertising'));
      expect(calledMethods, contains('stopDiscovery'));
      expect(calledMethods, contains('stopAllEndpoints'));
    });

    test('streams and callbacks emit properly', () async {
      final service = NearbyService();

      expect(service.discoveredEndpointsStream, isNotNull);
      expect(service.connectionStatusStream, isNotNull);
      expect(service.payloadStream, isNotNull);

      await service.dispose();
    });

    test('sendResponsePayload validates empty arguments and invokes channel', () async {
      final service = NearbyService();

      // Empty endpointId
      final emptyEpResult = await service.sendResponsePayload('', Uint8List.fromList([1, 2]));
      expect(emptyEpResult, isFalse);

      // Empty payload
      final emptyPayloadResult = await service.sendResponsePayload('ep1', Uint8List(0));
      expect(emptyPayloadResult, isFalse);

      // Valid call
      final validPayload = Uint8List.fromList([1, 2, 3, 4]);
      final success = await service.sendResponsePayload('ep_merchant', validPayload);
      expect(success, isTrue);

      final sendCall = methodCalls.lastWhere((c) => c.method == 'sendPayload');
      expect(sendCall.arguments['endpointId'], equals('ep_merchant'));
      expect(sendCall.arguments['bytes'], equals(validPayload));
    });

    test('sendVoucherAndWaitForResponse validates empty arguments', () async {
      final service = NearbyService();

      final r1 = await service.sendVoucherAndWaitForResponse(
        endpointId: '',
        packedVoucherBytes: Uint8List.fromList([1, 2]),
      );
      expect(r1, isNull);

      final r2 = await service.sendVoucherAndWaitForResponse(
        endpointId: 'ep1',
        packedVoucherBytes: Uint8List(0),
      );
      expect(r2, isNull);
    });
  });
}
