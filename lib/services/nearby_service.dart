import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Connection states for P2P Nearby connections.
enum NearbyConnectionStatus {
  connecting,
  connected,
  disconnected,
}

/// Represents a connection state change event for a specific endpoint.
class NearbyConnectionStateChange {
  final String endpointId;
  final NearbyConnectionStatus status;

  const NearbyConnectionStateChange({
    required this.endpointId,
    required this.status,
  });

  @override
  String toString() => 'NearbyConnectionStateChange($endpointId: $status)';
}

/// Represents a received byte payload from a nearby peer.
class NearbyPayloadReceived {
  final String endpointId;
  final Uint8List rawBytes;

  const NearbyPayloadReceived({
    required this.endpointId,
    required this.rawBytes,
  });

  @override
  String toString() => 'NearbyPayloadReceived(endpointId: $endpointId, bytes: ${rawBytes.length})';
}

/// Peer-to-peer communication service wrapping [Nearby] connections
/// using Strategy.P2P_STAR for OffPay (AirBirr) offline transactions.
///
/// Adheres strictly to OffPay guidelines:
/// - Service ID: 'et.airbirr.offpay'
/// - Strategy: Strategy.P2P_STAR (Star topology)
/// - Safe ephemeral connection lifecycle: auto-accept, payload transmission, auto-disconnect.
class NearbyService {
  static const String serviceId = 'et.airbirr.offpay';
  static const Strategy strategy = Strategy.P2P_STAR;

  final Nearby _nearby;

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  final Set<String> _connectedEndpoints = {};
  final Map<String, String> _discoveredEndpoints = {};

  final _discoveredEndpointsController = StreamController<Map<String, String>>.broadcast();
  final _connectionStatusController = StreamController<NearbyConnectionStateChange>.broadcast();
  final _payloadController = StreamController<NearbyPayloadReceived>.broadcast();

  /// Optional global callbacks
  void Function(Map<String, String> endpoints)? onDiscoveredEndpointsChanged;
  void Function(String endpointId, NearbyConnectionStatus status)? onConnectionStatusChanged;
  void Function(String endpointId, Uint8List rawBytes)? onGlobalPayloadReceived;

  NearbyService({Nearby? nearby}) : _nearby = nearby ?? Nearby();

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  Set<String> get connectedEndpoints => Set.unmodifiable(_connectedEndpoints);
  Map<String, String> get discoveredEndpoints => Map.unmodifiable(_discoveredEndpoints);

  /// Stream of currently discovered endpoints (endpointId -> endpointName).
  Stream<Map<String, String>> get discoveredEndpointsStream => _discoveredEndpointsController.stream;

  /// Stream of connection status changes (connecting, connected, disconnected).
  Stream<NearbyConnectionStateChange> get connectionStatusStream => _connectionStatusController.stream;

  /// Stream of received byte payloads from any peer.
  Stream<NearbyPayloadReceived> get payloadStream => _payloadController.stream;

  // ===========================================================================
  // 1. MERCHANT (ADVERTISING / RECEIVER) METHODS
  // ===========================================================================

  /// Starts advertising as a merchant receiver.
  ///
  /// - Enforces single active advertising session by stopping any previous session.
  /// - Automatically accepts incoming connections.
  /// - Listens for incoming byte payloads (`PayloadType.BYTES`) and invokes [onPayloadReceived].
  /// - Emits state events to streams and callbacks.
  Future<bool> startAdvertising({
    required String merchantName,
    required Function(String endpointId, Uint8List payload) onPayloadReceived,
  }) async {
    if (_isAdvertising) {
      developer.log('Already advertising. Stopping previous advertising session.', name: 'NearbyService');
      await stopAdvertising();
    }

    try {
      final success = await _nearby.startAdvertising(
        merchantName,
        strategy,
        serviceId: serviceId,
        onConnectionInitiated: (endpointId, connectionInfo) async {
          developer.log(
            'Incoming connection initiated from ${connectionInfo.endpointName} ($endpointId)',
            name: 'NearbyService',
          );
          _notifyConnectionStatus(endpointId, NearbyConnectionStatus.connecting);

          // Automatically accept connection requests from payers
          try {
            await _nearby.acceptConnection(
              endpointId,
              onPayLoadRecieved: (id, payload) {
                if (payload.type == PayloadType.BYTES && payload.bytes != null) {
                  final bytes = payload.bytes!;
                  developer.log(
                    'Received byte payload (${bytes.length} bytes) from $id',
                    name: 'NearbyService',
                  );
                  _payloadController.add(NearbyPayloadReceived(endpointId: id, rawBytes: bytes));
                  onGlobalPayloadReceived?.call(id, bytes);
                  onPayloadReceived(id, bytes);
                } else {
                  developer.log(
                    'Ignored non-byte or null payload from $id',
                    name: 'NearbyService',
                  );
                }
              },
            );
          } catch (e) {
            developer.log('Failed to accept connection from $endpointId: $e', name: 'NearbyService');
          }
        },
        onConnectionResult: (endpointId, status) {
          developer.log('Connection result for $endpointId: $status', name: 'NearbyService');
          if (status == Status.CONNECTED) {
            _connectedEndpoints.add(endpointId);
            _notifyConnectionStatus(endpointId, NearbyConnectionStatus.connected);
          } else {
            _connectedEndpoints.remove(endpointId);
            _notifyConnectionStatus(endpointId, NearbyConnectionStatus.disconnected);
          }
        },
        onDisconnected: (endpointId) {
          developer.log('Endpoint $endpointId disconnected', name: 'NearbyService');
          _connectedEndpoints.remove(endpointId);
          _notifyConnectionStatus(endpointId, NearbyConnectionStatus.disconnected);
        },
      );

      _isAdvertising = success;
      developer.log('Advertising started: $success (merchant: $merchantName)', name: 'NearbyService');
      return success;
    } catch (e) {
      developer.log('Error starting advertising: $e', name: 'NearbyService');
      _isAdvertising = false;
      return false;
    }
  }

  // ===========================================================================
  // 2. CUSTOMER (DISCOVERY / SENDER) METHODS
  // ===========================================================================

  /// Starts discovery scanning for nearby merchant endpoints.
  ///
  /// - Enforces single active discovery session by stopping any previous session.
  /// - Invokes [onEndpointFound] when an endpoint is discovered.
  /// - Invokes [onEndpointLost] when an endpoint is lost.
  /// - Updates [discoveredEndpointsStream] and [discoveredEndpoints].
  Future<bool> startDiscovery({
    required Function(String endpointId, String endpointName) onEndpointFound,
    required Function(String endpointId) onEndpointLost,
    String userName = 'OffPayCustomer',
  }) async {
    if (_isDiscovering) {
      developer.log('Already discovering. Stopping previous discovery session.', name: 'NearbyService');
      await stopDiscovery();
    }

    try {
      final success = await _nearby.startDiscovery(
        userName,
        strategy,
        serviceId: serviceId,
        onEndpointFound: (endpointId, endpointName, foundServiceId) {
          developer.log(
            'Discovered merchant: $endpointName ($endpointId) on service $foundServiceId',
            name: 'NearbyService',
          );
          _discoveredEndpoints[endpointId] = endpointName;
          _notifyEndpointsChanged();
          onEndpointFound(endpointId, endpointName);
        },
        onEndpointLost: (endpointId) {
          developer.log('Lost endpoint: $endpointId', name: 'NearbyService');
          if (endpointId != null) {
            _discoveredEndpoints.remove(endpointId);
            _notifyEndpointsChanged();
            onEndpointLost(endpointId);
          }
        },
      );

      _isDiscovering = success;
      developer.log('Discovery started: $success', name: 'NearbyService');
      return success;
    } catch (e) {
      developer.log('Error starting discovery: $e', name: 'NearbyService');
      _isDiscovering = false;
      return false;
    }
  }

  /// Transmits a packed voucher payload to a merchant endpoint with safe connection lifecycle:
  /// 1. Requests connection via `requestConnection`.
  /// 2. Auto-accepts connection on initiation and registers payload response handler.
  /// 3. On mutual acceptance (`Status.CONNECTED`), transmits bytes via `sendBytesPayload`.
  /// 4. If [waitForResponse] is true, awaits merchant's ACK/NACK response payload.
  /// 5. Completes cleanly and auto-disconnects from endpoint after transmission/response.
  /// 6. Times out after [timeout] (default 10 seconds).
  Future<bool> sendVoucherPayload({
    required String endpointId,
    required Uint8List packedVoucherBytes,
    String clientName = 'OffPayPayer',
    Duration timeout = const Duration(seconds: 10),
    void Function(Uint8List responseBytes)? onResponseReceived,
    bool waitForResponse = false,
  }) async {
    if (endpointId.trim().isEmpty) {
      developer.log('Endpoint ID cannot be empty', name: 'NearbyService');
      return false;
    }

    if (packedVoucherBytes.isEmpty) {
      developer.log('Voucher bytes cannot be empty', name: 'NearbyService');
      return false;
    }

    final completer = Completer<bool>();
    final responseCompleter = Completer<Uint8List?>();
    Timer? timeoutTimer;

    // Timeout guard to prevent hanging connections
    timeoutTimer = Timer(timeout, () async {
      if (!completer.isCompleted) {
        developer.log(
          'sendVoucherPayload to $endpointId timed out after ${timeout.inSeconds}s',
          name: 'NearbyService',
        );
        try {
          await _nearby.disconnectFromEndpoint(endpointId);
        } catch (_) {}
        _connectedEndpoints.remove(endpointId);
        _notifyConnectionStatus(endpointId, NearbyConnectionStatus.disconnected);
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(null);
        }
        completer.complete(false);
      }
    });

    try {
      final requested = await _nearby.requestConnection(
        clientName,
        endpointId,
        onConnectionInitiated: (id, connectionInfo) async {
          developer.log(
            'Client connection initiated with $id (${connectionInfo.endpointName})',
            name: 'NearbyService',
          );
          _notifyConnectionStatus(id, NearbyConnectionStatus.connecting);

          try {
            await _nearby.acceptConnection(
              id,
              onPayLoadRecieved: (receivedId, receivedPayload) {
                if (receivedPayload.type == PayloadType.BYTES && receivedPayload.bytes != null) {
                  final bytes = receivedPayload.bytes!;
                  developer.log(
                    'Client received response payload (${bytes.length} bytes) from $receivedId',
                    name: 'NearbyService',
                  );
                  _payloadController.add(NearbyPayloadReceived(endpointId: receivedId, rawBytes: bytes));
                  onGlobalPayloadReceived?.call(receivedId, bytes);
                  onResponseReceived?.call(bytes);
                  if (!responseCompleter.isCompleted) {
                    responseCompleter.complete(bytes);
                  }
                }
              },
            );
          } catch (e) {
            developer.log('Failed to accept connection from $id on client side: $e', name: 'NearbyService');
            if (!responseCompleter.isCompleted) {
              responseCompleter.complete(null);
            }
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          }
        },
        onConnectionResult: (id, status) async {
          developer.log('Client connection result with $id: $status', name: 'NearbyService');
          if (status == Status.CONNECTED) {
            _connectedEndpoints.add(id);
            _notifyConnectionStatus(id, NearbyConnectionStatus.connected);

            try {
              // Send packed voucher bytes
              await _nearby.sendBytesPayload(id, packedVoucherBytes);
              developer.log('Voucher payload sent to $id successfully', name: 'NearbyService');

              if (waitForResponse) {
                // Wait for the merchant's ACK / NACK response payload
                final resp = await responseCompleter.future;
                if (!completer.isCompleted) {
                  completer.complete(resp != null);
                }
              } else {
                if (!completer.isCompleted) {
                  completer.complete(true);
                }
              }
            } catch (e) {
              developer.log('Error transmitting voucher payload to $id: $e', name: 'NearbyService');
              if (!responseCompleter.isCompleted) {
                responseCompleter.complete(null);
              }
              if (!completer.isCompleted) {
                completer.complete(false);
              }
            } finally {
              // Auto-disconnect after transmission and response
              try {
                await _nearby.disconnectFromEndpoint(id);
                _connectedEndpoints.remove(id);
                _notifyConnectionStatus(id, NearbyConnectionStatus.disconnected);
                developer.log('Auto-disconnected from $id after transaction', name: 'NearbyService');
              } catch (e) {
                developer.log('Error disconnecting from $id: $e', name: 'NearbyService');
              }
            }
          } else {
            developer.log('Connection failed or rejected for $id: $status', name: 'NearbyService');
            _connectedEndpoints.remove(id);
            _notifyConnectionStatus(id, NearbyConnectionStatus.disconnected);
            if (!responseCompleter.isCompleted) {
              responseCompleter.complete(null);
            }
            if (!completer.isCompleted) {
              completer.complete(false);
            }
          }
        },
        onDisconnected: (id) {
          developer.log('Endpoint $id disconnected', name: 'NearbyService');
          _connectedEndpoints.remove(id);
          _notifyConnectionStatus(id, NearbyConnectionStatus.disconnected);
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete(null);
          }
        },
      );

      if (!requested) {
        timeoutTimer.cancel();
        developer.log('Request connection failed for endpoint $endpointId', name: 'NearbyService');
        return false;
      }

      final result = await completer.future;
      timeoutTimer.cancel();
      return result;
    } catch (e) {
      timeoutTimer.cancel();
      developer.log('Exception in sendVoucherPayload: $e', name: 'NearbyService');
      return false;
    }
  }

  /// Transmits a packed voucher payload to a merchant and awaits the merchant's ACK/NACK response.
  ///
  /// - Returns the decoded response [Map] if ACK or NACK is received within [timeout].
  /// - Returns `null` if the transmission failed, timed out, or response could not be parsed.
  Future<Map<String, dynamic>?> sendVoucherAndWaitForResponse({
    required String endpointId,
    required Uint8List packedVoucherBytes,
    String clientName = 'OffPayPayer',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (endpointId.trim().isEmpty || packedVoucherBytes.isEmpty) {
      return null;
    }

    Uint8List? responseBytes;
    final success = await sendVoucherPayload(
      endpointId: endpointId,
      packedVoucherBytes: packedVoucherBytes,
      clientName: clientName,
      timeout: timeout,
      waitForResponse: true,
      onResponseReceived: (bytes) {
        responseBytes = bytes;
      },
    );

    if (success && responseBytes != null && responseBytes!.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(responseBytes!));
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (e) {
        developer.log('Error parsing response JSON: $e', name: 'NearbyService');
      }
    }
    return null;
  }

  /// Sends a response payload (such as an ACK/NACK confirmation) to a connected peer endpoint.
  Future<bool> sendResponsePayload(String endpointId, Uint8List payload) async {
    if (endpointId.trim().isEmpty || payload.isEmpty) {
      developer.log('Endpoint ID or payload empty in sendResponsePayload', name: 'NearbyService');
      return false;
    }
    try {
      await _nearby.sendBytesPayload(endpointId, payload);
      developer.log(
        'Response payload (${payload.length} bytes) sent to $endpointId successfully',
        name: 'NearbyService',
      );
      return true;
    } catch (e) {
      developer.log('Error sending response payload to $endpointId: $e', name: 'NearbyService');
      return false;
    }
  }

  /// Backward-compatible connect and send method.
  Future<bool> connectAndSendPayload({
    required String endpointId,
    required Uint8List payload,
    required void Function() onSent,
    String clientName = 'OffPayPayer',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final success = await sendVoucherPayload(
      endpointId: endpointId,
      packedVoucherBytes: payload,
      clientName: clientName,
      timeout: timeout,
    );
    if (success) {
      onSent();
    }
    return success;
  }

  // ===========================================================================
  // 3. LIFECYCLE & TEARDOWN
  // ===========================================================================

  /// Stops advertising session.
  Future<void> stopAdvertising() async {
    try {
      await _nearby.stopAdvertising();
      _isAdvertising = false;
      developer.log('Stopped advertising', name: 'NearbyService');
    } catch (e) {
      developer.log('Error stopping advertising: $e', name: 'NearbyService');
      _isAdvertising = false;
    }
  }

  /// Stops discovery scanning session.
  Future<void> stopDiscovery() async {
    try {
      await _nearby.stopDiscovery();
      _isDiscovering = false;
      developer.log('Stopped discovery', name: 'NearbyService');
    } catch (e) {
      developer.log('Error stopping discovery: $e', name: 'NearbyService');
      _isDiscovering = false;
    }
  }

  /// Calls `stopAdvertising()`, `stopDiscovery()`, and `stopAllEndpoints()`.
  /// Resets all internal connection and discovery states.
  Future<void> stopAll() async {
    try {
      if (_isAdvertising) {
        await stopAdvertising();
      }
    } catch (_) {}

    try {
      if (_isDiscovering) {
        await stopDiscovery();
      }
    } catch (_) {}

    try {
      await _nearby.stopAllEndpoints();
    } catch (e) {
      developer.log('Error stopping all nearby connections: $e', name: 'NearbyService');
    }

    _isAdvertising = false;
    _isDiscovering = false;
    _connectedEndpoints.clear();
    _discoveredEndpoints.clear();
    _notifyEndpointsChanged();
    developer.log('All nearby operations stopped and internal states reset', name: 'NearbyService');
  }

  /// Closes internal stream controllers.
  Future<void> dispose() async {
    await stopAll();
    await _discoveredEndpointsController.close();
    await _connectionStatusController.close();
    await _payloadController.close();
  }

  void _notifyConnectionStatus(String endpointId, NearbyConnectionStatus status) {
    final event = NearbyConnectionStateChange(endpointId: endpointId, status: status);
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(event);
    }
    onConnectionStatusChanged?.call(endpointId, status);
  }

  void _notifyEndpointsChanged() {
    final map = Map<String, String>.unmodifiable(_discoveredEndpoints);
    if (!_discoveredEndpointsController.isClosed) {
      _discoveredEndpointsController.add(map);
    }
    onDiscoveredEndpointsChanged?.call(map);
  }
}

/// Riverpod provider for [NearbyService].
final nearbyServiceProvider = Provider<NearbyService>((ref) {
  final service = NearbyService();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});
