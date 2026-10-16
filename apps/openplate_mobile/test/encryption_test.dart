import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/encryption.dart';
import 'package:openplate_mobile/connection_url.dart';

void main() {
  final vector =
      jsonDecode(
            File(
              '../../tests/fixtures/encrypted_transport_v2.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final envelope = vector['envelope'] as Map<String, dynamic>;
  final now = DateTime.fromMillisecondsSinceEpoch(
    (envelope['timestamp'] as int) * 1000,
  );
  test(
    'Python and Dart share the same AES-GCM/HKDF ciphertext and plaintext',
    () async {
      final result = await EncryptedTransport.seal(
        vector['payload'] as Map<String, dynamic>,
        vector['secret'] as String,
        vector['context'] as String,
        messageId: envelope['id'] as String,
        now: now,
        nonce: List.generate(12, (i) => i),
      );
      expect(result, envelope);
      expect(
        await EncryptedTransport.unseal(
          envelope,
          vector['secret'] as String,
          vector['context'] as String,
          now: now,
        ),
        vector['payload'],
      );
    },
  );

  test('tampering, reflection, wrong keys and expiry fail closed', () async {
    for (final modified in [
      {...envelope, 'timestamp': (envelope['timestamp'] as int) + 1},
      {...envelope, 'id': 'tampered0123456789'},
      {...envelope, 'nonce': 'AAAAAAAAAAAAAAAA'},
      {...envelope, 'ciphertext': 'AAAAAAAAAAAAAAAAAAAAAA'},
      {...envelope, 'version': 1},
    ]) {
      await expectLater(
        EncryptedTransport.unseal(
          modified,
          vector['secret'] as String,
          vector['context'] as String,
          now: now,
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      EncryptedTransport.unseal(
        envelope,
        'w' * 43,
        vector['context'] as String,
        now: now,
      ),
      throwsFormatException,
    );
    await expectLater(
      EncryptedTransport.unseal(
        envelope,
        vector['secret'] as String,
        'device/response/other',
        now: now,
      ),
      throwsFormatException,
    );
    await expectLater(
      EncryptedTransport.unseal(
        envelope,
        vector['secret'] as String,
        vector['context'] as String,
        now: now.add(const Duration(seconds: 91)),
      ),
      throwsFormatException,
    );
  });

  test('local HTTP URL policy matches Home Assistant', () {
    for (final value in [
      'http://homeassistant.local:8123',
      'http://192.168.1.5:8123',
      'http://[fd00::1]:8123',
      'https://ha.example.test',
    ]) {
      expect(isHomeAssistantUrl(Uri.parse(value)), isTrue, reason: value);
    }
    for (final value in [
      'http://example.com',
      'http://8.8.8.8',
      'https://user:password@ha.local',
      'http://ha.local?key=secret',
    ]) {
      expect(isHomeAssistantUrl(Uri.parse(value)), isFalse, reason: value);
    }
  });
}
