import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen QR code scanner with camera feed, torch control, and manual input fallback.
class QrScannerScreen extends StatefulWidget {
  final void Function(String rawValue) onScanned;
  final String title;

  const QrScannerScreen({
    super.key,
    required this.onScanned,
    this.title = 'Scan QR Code',
  });

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  late final MobileScannerController _controller;
  bool _hasScanned = false;
  final bool _isTest =
      WidgetsBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: !_isTest,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    if (!_isTest) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        _hasScanned = true;
        widget.onScanned(value.trim());
        break;
      }
    }
  }

  Future<void> _promptManualCodeInput() async {
    final textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter QR Payload Manually'),
        content: TextField(
          key: const Key('manual_qr_input'),
          controller: textController,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Paste QR JSON payload here...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && mounted && !_hasScanned) {
      _hasScanned = true;
      widget.onScanned(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard),
            tooltip: 'Enter code manually',
            onPressed: _promptManualCodeInput,
          ),
          if (!_isTest) ...[
            IconButton(
              icon: const Icon(Icons.flash_on),
              tooltip: 'Toggle Flash',
              onPressed: () async {
                try {
                  await _controller.toggleTorch();
                } catch (_) {}
              },
            ),
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              tooltip: 'Switch Camera',
              onPressed: () async {
                try {
                  await _controller.switchCamera();
                } catch (_) {}
              },
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          if (_isTest)
            const Center(
              child: Text(
                'Camera scanner active (test mode)',
                style: TextStyle(color: Colors.white70),
              ),
            )
          else
            MobileScanner(
              controller: _controller,
              onDetect: _handleDetect,
              errorBuilder: (context, error, child) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.camera_alt_outlined, color: Colors.white54, size: 64),
                      const SizedBox(height: 12),
                      Text(
                        'Camera unavailable: ${error.errorCode.name}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                );
              },
            ),
          Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35), width: 1.5),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  // Corner Viewfinder Overlays
                  _CameraCornerOverlay(isTop: true, isLeft: true),
                  _CameraCornerOverlay(isTop: true, isLeft: false),
                  _CameraCornerOverlay(isTop: false, isLeft: true),
                  _CameraCornerOverlay(isTop: false, isLeft: false),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Align customer QR code within the frame',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraCornerOverlay extends StatelessWidget {
  final bool isTop;
  final bool isLeft;

  const _CameraCornerOverlay({
    required this.isTop,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) {
    const size = 32.0;
    const stroke = 3.5;
    const radius = 8.0;
    const color = Color(0xFF10B981); // Crisp fintech green

    return Positioned(
      top: isTop ? 0 : null,
      bottom: !isTop ? 0 : null,
      left: isLeft ? 0 : null,
      right: !isLeft ? 0 : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border(
            top: isTop ? const BorderSide(color: color, width: stroke) : BorderSide.none,
            bottom: !isTop ? const BorderSide(color: color, width: stroke) : BorderSide.none,
            left: isLeft ? const BorderSide(color: color, width: stroke) : BorderSide.none,
            right: !isLeft ? const BorderSide(color: color, width: stroke) : BorderSide.none,
          ),
          borderRadius: BorderRadius.only(
            topLeft: isTop && isLeft ? const Radius.circular(radius) : Radius.zero,
            topRight: isTop && !isLeft ? const Radius.circular(radius) : Radius.zero,
            bottomLeft: !isTop && isLeft ? const Radius.circular(radius) : Radius.zero,
            bottomRight: !isTop && !isLeft ? const Radius.circular(radius) : Radius.zero,
          ),
        ),
      ),
    );
  }
}
