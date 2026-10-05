import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../../payment_outbox/data/sqlite_payment_outbox_repository.dart';
import '../domain/signed_sms_deposit_parser.dart';

abstract interface class SmsDepositReleaseStore {
  Future<List<SignedSmsDepositRelease>> current(DateTime now);
  Future<bool> install(String bundle, DateTime now);
}

/// Signature, configured parser signing pin, expiry, and version are checked on every
/// read. SQLite retains the whole signed bundle inside Keystore ciphertext.
final class EncryptedSmsReleaseStore implements SmsDepositReleaseStore {
  EncryptedSmsReleaseStore._(this._database, this._cipher, this._verifier);
  final Database _database;
  final PaymentOutboxCipher _cipher;
  final SignedSmsDepositReleaseVerifier _verifier;

  static Future<EncryptedSmsReleaseStore> open({
    required SignedSmsDepositReleaseVerifier verifier,
    PaymentOutboxCipher? cipher,
    PaymentOutboxStorageLocation? location,
  }) async {
    const PlatformPaymentOutboxCipher platform = PlatformPaymentOutboxCipher();
    final Database db = await openDatabase(join(await (location ?? platform).directory(), 'signed-sms-releases.db'),
      version: 1, onCreate: (Database db, int _) => db.execute(
        'CREATE TABLE releases (record_id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL)'),
      onUpgrade: (_, _, _) => throw const OutboxRecoveryRequiredException());
    return EncryptedSmsReleaseStore._(db, cipher ?? platform, verifier);
  }

  Future<void> close() => _database.close();

  Future<List<({String id, String bundle})>> _read() async {
    final List<Map<String, Object?>> rows = await _database.query('releases');
    if (rows.length > 64) throw const OutboxRecoveryRequiredException();
    final List<({String id, String bundle})> result = <({String id, String bundle})>[];
    for (final Map<String, Object?> row in rows) {
      final Object? id = row['record_id'];
      final Object? ciphertext = row['ciphertext'];
      if (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) || ciphertext is! String) {
        throw const OutboxRecoveryRequiredException();
      }
      result.add((id: id, bundle: await _cipher.decrypt(identity: id, ciphertext: ciphertext)));
    }
    return result;
  }

  @override
  Future<List<SignedSmsDepositRelease>> current(DateTime now) async {
    final List<SignedSmsDepositRelease> result = <SignedSmsDepositRelease>[];
    final Set<String> senders = <String>{};
    for (final item in await _read()) {
      final SignedSmsDepositRelease? release = await _verifier.verify(item.bundle, now);
      // Expired or nonmatching authority stays durably retained for review.
      if (release == null) continue;
      if (!senders.add(release.sender)) throw const OutboxRecoveryRequiredException();
      result.add(release);
    }
    return result;
  }

  @override
  Future<bool> install(String bundle, DateTime now) async {
    final SignedSmsDepositRelease? incoming = await _verifier.verify(bundle, now);
    if (incoming == null) return false;
    final rows = await _read();
    String? replaceId;
    for (final row in rows) {
      // An expired stored release must still block rollback. Its authenticated
      // ciphertext retains the previously verified sender/version authority.
      final Object? decoded = jsonDecode(row.bundle);
      if (decoded is! Map<String, dynamic>) {
        throw const OutboxRecoveryRequiredException();
      }
      final Object? storedValue = decoded.containsKey('release') ? decoded['release'] : decoded;
      if (storedValue is! Map<String, dynamic>) throw const OutboxRecoveryRequiredException();
      final Map<String, dynamic> stored = storedValue;
      if (stored['sender'] != incoming.sender) continue;
      final Object? version = stored['pattern_version'];
      if (version is! int) throw const OutboxRecoveryRequiredException();
      if (version > incoming.version) return false;
      if (version == incoming.version) {
        return sha256.convert(SignedSmsDepositReleaseVerifier.canonicalPayload(stored)).toString() == incoming.releaseId;
      }
      replaceId = row.id;
    }
    if (replaceId == null && rows.length >= 64) return false;
    final Random random = Random.secure();
    final String id = replaceId ?? List<String>.generate(64, (_) => '0123456789abcdef'[random.nextInt(16)]).join();
    final String encrypted = await _cipher.encrypt(identity: id, cleartext: bundle);
    await _database.transaction((Transaction txn) async {
      await txn.insert('releases', <String, Object>{'record_id': id, 'ciphertext': encrypted},
        conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return true;
  }
}
