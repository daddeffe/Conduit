import 'package:uuid/uuid.dart';

class SavedPortForwardConfig {
  const SavedPortForwardConfig({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    this.name = '',
    this.localPort,
  });

  factory SavedPortForwardConfig.create({
    String? name,
    int? localPort,
    required String remoteHost,
    required int remotePort,
  }) {
    return SavedPortForwardConfig(
      id: const Uuid().v4(),
      name: name ?? '',
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );
  }

  final String id;
  final String name;
  final int? localPort;
  final String remoteHost;
  final int remotePort;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'localPort': localPort,
      'remoteHost': remoteHost,
      'remotePort': remotePort,
    };
  }

  factory SavedPortForwardConfig.fromJson(Map<String, Object?> json) {
    return SavedPortForwardConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      localPort: json['localPort'] as int?,
      remoteHost: json['remoteHost'] as String? ?? '',
      remotePort: json['remotePort'] as int? ?? 0,
    );
  }
}
