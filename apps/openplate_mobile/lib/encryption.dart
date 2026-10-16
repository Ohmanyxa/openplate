import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

/// Wire specification: docs/ENCRYPTED_TRANSPORT.md. No plaintext fallback.
class EncryptedTransport {
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  static Future<SecretKey> _key(String secret, String context) {
    if (secret.length < 32) throw const FormatException('Schlüssel zu kurz');
    return _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: utf8.encode('openplate/v2/hkdf-sha256'),
      info: utf8.encode('openplate/v2/$context'),
    );
  }

  static String _encode(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static List<int> _decode(dynamic value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(value)) {
      throw const FormatException('Ungültige verschlüsselte Nachricht');
    }
    return base64Url.decode(base64Url.normalize(value));
  }

  static Future<Map<String, dynamic>> seal(
    Map<String, dynamic> payload,
    String secret,
    String context, {
    String? messageId,
    DateTime? now,
    List<int>? nonce,
  }) async {
    final id = messageId ?? const Uuid().v4();
    if (!_idPattern.hasMatch(id)) {
      throw const FormatException('Ungültige Nachrichten-ID');
    }
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: await _key(secret, context),
      nonce: nonce ?? _aes.newNonce(),
      aad: utf8.encode('openplate/v2\n$context\n$id\n$timestamp'),
    );
    return {
      'version': 2,
      'id': id,
      'timestamp': timestamp,
      'nonce': _encode(box.nonce),
      'ciphertext': _encode([...box.cipherText, ...box.mac.bytes]),
    };
  }

  static Future<Map<String, dynamic>> unseal(
    dynamic envelope,
    String secret,
    String context, {
    DateTime? now,
  }) async {
    try {
      if (envelope is! Map<String, dynamic> || envelope['version'] != 2) {
        throw const FormatException('Verschlüsselte Antwort erforderlich');
      }
      final id = envelope['id'];
      final timestamp = envelope['timestamp'];
      if (id is! String ||
          !_idPattern.hasMatch(id) ||
          timestamp is! int ||
          (((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) - timestamp)
                  .abs() >
              90) {
        throw const FormatException('Ungültige oder veraltete Nachricht');
      }
      final nonce = _decode(envelope['nonce']);
      final cipher = _decode(envelope['ciphertext']);
      if (nonce.length != 12 || cipher.length < 16) {
        throw const FormatException('Ungültige verschlüsselte Nachricht');
      }
      final bytes = await _aes.decrypt(
        SecretBox(
          cipher.sublist(0, cipher.length - 16),
          nonce: nonce,
          mac: Mac(cipher.sublist(cipher.length - 16)),
        ),
        secretKey: await _key(secret, context),
        aad: utf8.encode('openplate/v2\n$context\n$id\n$timestamp'),
      );
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Ungültige Nutzdaten');
      }
      return payload;
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'Die Nachricht konnte nicht authentifiziert werden',
      );
    }
  }
}
