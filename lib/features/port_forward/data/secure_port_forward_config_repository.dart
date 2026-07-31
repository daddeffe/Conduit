import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/port_forward/domain/port_forward_config_repository.dart';
import 'package:conduit/features/port_forward/domain/saved_port_forward_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecurePortForwardConfigRepository
    implements PortForwardConfigRepository {
  const SecurePortForwardConfigRepository(this._storage);

  static const _configsKey = 'conduit.port_forward_configs.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<SavedPortForwardConfig>> loadConfigs() async {
    final raw = await _storage.read(key: _configsKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Expected a list of port forward configs.');
      }

      return decoded
          .whereType<Map<String, Object?>>()
          .map(SavedPortForwardConfig.fromJson)
          .toList(growable: false);
    } catch (error) {
      throw AppFailure('Port forward configs could not be read.', error);
    }
  }

  @override
  Future<void> saveConfigs(List<SavedPortForwardConfig> configs) async {
    await _storage.write(
      key: _configsKey,
      value: jsonEncode(configs.map((c) => c.toJson()).toList()),
    );
  }

  @override
  Future<void> addConfig(SavedPortForwardConfig config) async {
    final configs = await loadConfigs();
    configs.add(config);
    await saveConfigs(configs);
  }

  @override
  Future<void> removeConfig(String id) async {
    final configs = await loadConfigs();
    configs.removeWhere((c) => c.id == id);
    await saveConfigs(configs);
  }
}
