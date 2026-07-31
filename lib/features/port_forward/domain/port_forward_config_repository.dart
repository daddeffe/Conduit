import 'package:conduit/features/port_forward/domain/saved_port_forward_config.dart';

abstract interface class PortForwardConfigRepository {
  Future<List<SavedPortForwardConfig>> loadConfigs();

  Future<void> saveConfigs(List<SavedPortForwardConfig> configs);

  Future<void> addConfig(SavedPortForwardConfig config);

  Future<void> removeConfig(String id);
}
