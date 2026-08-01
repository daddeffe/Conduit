import 'package:uuid/uuid.dart';

enum ForwardStatus { idle, connecting, active, error }

class SavedPersistentForward {
  const SavedPersistentForward({
    required this.id,
    required this.name,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.hostId,
    this.autoReconnect = true,
    this.status = ForwardStatus.idle,
  });

  factory SavedPersistentForward.create({
    required String name,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required String hostId,
    bool autoReconnect = true,
  }) {
    return SavedPersistentForward(
      id: const Uuid().v4(),
      name: name,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      hostId: hostId,
      autoReconnect: autoReconnect,
    );
  }

  final String id;
  final String name;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final String hostId;
  final bool autoReconnect;
  final ForwardStatus status;

  SavedPersistentForward copyWith({
    String? id,
    String? name,
    int? localPort,
    String? remoteHost,
    int? remotePort,
    String? hostId,
    bool? autoReconnect,
    ForwardStatus? status,
  }) {
    return SavedPersistentForward(
      id: id ?? this.id,
      name: name ?? this.name,
      localPort: localPort ?? this.localPort,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
      hostId: hostId ?? this.hostId,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      status: status ?? this.status,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'localPort': localPort,
      'remoteHost': remoteHost,
      'remotePort': remotePort,
      'hostId': hostId,
      'autoReconnect': autoReconnect,
    };
  }

  factory SavedPersistentForward.fromJson(Map<String, Object?> json) {
    return SavedPersistentForward(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      localPort: json['localPort'] as int? ?? 0,
      remoteHost: json['remoteHost'] as String? ?? '',
      remotePort: json['remotePort'] as int? ?? 0,
      hostId: json['hostId'] as String? ?? '',
      autoReconnect: json['autoReconnect'] as bool? ?? true,
    );
  }
}
