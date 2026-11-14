// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final publicKeyBytes = publicKey.bytes;

  if (publicKeyBytes.length != 32) {
    throw StateError(
      'Expected a 32-byte Ed25519 public key, got ${publicKeyBytes.length}.',
    );
  }

  print('Ed25519 public key (base64):');
  print(base64Encode(publicKeyBytes));
}

