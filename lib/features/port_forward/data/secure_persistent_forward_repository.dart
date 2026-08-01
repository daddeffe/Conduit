import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/port_forward/domain/persistent_forward_repository.dart';
import 'package:conduit/features/port_forward/domain/saved_persistent_forward.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecurePersistentForwardRepository
    implements PersistentForwardRepository {
  const SecurePersistentForwardRepository(this._storage);

  static const _forwardsKey = 'conduit.persistent_forwards.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<SavedPersistentForward>> loadForwards() async {
    final raw = await _storage.read(key: _forwardsKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Expected a list of persistent forwards.');
      }

      return decoded
          .whereType<Map<String, Object?>>()
          .map(SavedPersistentForward.fromJson)
          .toList(growable: false);
    } catch (error) {
      throw AppFailure('Persistent forwards could not be read.', error);
    }
  }

  @override
  Future<void> saveForwards(List<SavedPersistentForward> forwards) async {
    await _storage.write(
      key: _forwardsKey,
      value: jsonEncode(forwards.map((f) => f.toJson()).toList()),
    );
  }

  @override
  Future<void> addForward(SavedPersistentForward forward) async {
    final forwards = await loadForwards();
    forwards.add(forward);
    await saveForwards(forwards);
  }

  @override
  Future<void> removeForward(String id) async {
    final forwards = await loadForwards();
    forwards.removeWhere((f) => f.id == id);
    await saveForwards(forwards);
  }
}
