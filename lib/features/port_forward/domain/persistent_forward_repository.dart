import 'package:conduit/features/port_forward/domain/saved_persistent_forward.dart';

abstract interface class PersistentForwardRepository {
  Future<List<SavedPersistentForward>> loadForwards();

  Future<void> saveForwards(List<SavedPersistentForward> forwards);

  Future<void> addForward(SavedPersistentForward forward);

  Future<void> removeForward(String id);
}
