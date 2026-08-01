import 'dart:async';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/port_forward/domain/forward_tunnel.dart';
import 'package:conduit/features/port_forward/domain/saved_persistent_forward.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:flutter/foundation.dart';

class PersistentForwardController extends ChangeNotifier {
  PersistentForwardController({
    required SavedHostsRepository hostsRepository,
    required SshClientFactory clientFactory,
    required SavedHost? Function(String hostId) hostResolver,
  })  : _hostsRepository = hostsRepository,
        _clientFactory = clientFactory,
        _hostResolver = hostResolver;

  final SavedHostsRepository _hostsRepository;
  final SshClientFactory _clientFactory;
  final SavedHost? Function(String hostId) _hostResolver;

  List<SavedPersistentForward> _forwards = const [];
  final _tunnels = <String, ForwardTunnel>{};
  final _clients = <String, SSHClient>{};
  final _tunnelGenerations = <String, int>{};

  List<SavedPersistentForward> get forwards =>
      List.unmodifiable(_forwards);

  int get activeForwardCount =>
      _forwards.where((f) => f.status == ForwardStatus.active).length;

  ForwardTunnel? tunnelFor(String id) => _tunnels[id];

  Future<void> load() async {
    try {
      final hosts = await _hostsRepository.loadHosts();
      _forwards = [
        for (final host in hosts)
          for (final fwd in host.persistentForwards)
            if (!_forwards.any((f) => f.id == fwd.id)) fwd,
      ];
      notifyListeners();

      for (final forward in _forwards) {
        if (forward.autoReconnect) {
          _updateStatus(forward.id, ForwardStatus.connecting);
          unawaited(_startTunnel(forward));
        }
      }
    } catch (_) {
      _forwards = const [];
      notifyListeners();
    }
  }

  Future<void> _saveHostForForward(SavedPersistentForward forward) async {
    final host = _hostResolver(forward.hostId);
    if (host == null) return;
    final hosts = await _hostsRepository.loadHosts();
    final index = hosts.indexWhere((h) => h.id == host.id);
    if (index == -1) return;
    hosts[index] = hosts[index].copyWith(persistentForwards: [
      for (final h in hosts)
        if (h.id == host.id)
          for (final fwd in h.persistentForwards)
            if (fwd.id != forward.id) fwd,
      forward,
    ]);
    await _hostsRepository.saveHosts(hosts);
  }

  Future<void> _removeHostForward(String fwdId, String hostId) async {
    final hosts = await _hostsRepository.loadHosts();
    final index = hosts.indexWhere((h) => h.id == hostId);
    if (index == -1) return;
    hosts[index] = hosts[index].copyWith(persistentForwards: [
      for (final fwd in hosts[index].persistentForwards)
        if (fwd.id != fwdId) fwd,
    ]);
    await _hostsRepository.saveHosts(hosts);
  }

  bool hasForwardWithName(String name) =>
      _forwards.any((f) => f.name.toLowerCase() == name.trim().toLowerCase());

  Future<void> addAndSaveForward(SavedPersistentForward forward) async {
    if (hasForwardWithName(forward.name)) return;
    _forwards = [..._forwards, forward];
    _updateStatus(forward.id, ForwardStatus.connecting);
    await _startTunnel(forward);
    try {
      await _saveHostForForward(forward);
    } catch (_) {
      // Host save failure is non-fatal for forward start
    }
  }

  Future<void> startForward(SavedPersistentForward forward) async {
    if (_forwards.any((f) => f.id == forward.id)) {
      _updateStatus(forward.id, ForwardStatus.connecting);
      await _startTunnel(forward);
    } else {
      await addAndSaveForward(forward);
    }
  }

  Future<void> _startTunnel(SavedPersistentForward forward) async {
    final gen = (_tunnelGenerations[forward.id] ?? 0) + 1;
    _tunnelGenerations[forward.id] = gen;

    try {
      final host = _hostResolver(forward.hostId);
      if (host == null) {
        _updateStatus(forward.id, ForwardStatus.error);
        return;
      }

      final client = await _clientFactory.connect(host);
      if (gen != _tunnelGenerations[forward.id]) {
        client.close();
        return;
      }

      final tunnel = ForwardTunnel(
        localPort: forward.localPort,
        remoteHost: forward.remoteHost,
        remotePort: forward.remotePort,
        client: client,
      );

      await tunnel.start();
      if (gen != _tunnelGenerations[forward.id]) {
        unawaited(tunnel.close());
        client.close();
        return;
      }

      _clients[forward.id] = client;
      _tunnels[forward.id] = tunnel;
      _updateStatus(forward.id, ForwardStatus.active);
    } catch (_) {
      if (gen == _tunnelGenerations[forward.id]) {
        _updateStatus(forward.id, ForwardStatus.error);
      }
    }
  }

  Future<void> stopForward(String id) async {
    _tunnelGenerations[id] = (_tunnelGenerations[id] ?? 0) + 1;

    final tunnel = _tunnels.remove(id);
    await tunnel?.close();

    final client = _clients.remove(id);
    client?.close();

    _updateStatus(id, ForwardStatus.idle);
  }

  Future<void> removeForward(String id) async {
    final hostId = _forwards.firstWhere((f) => f.id == id).hostId;
    await stopForward(id);
    try {
      await _removeHostForward(id, hostId);
    } catch (_) {
      // Storage failure is non-fatal for removal
    }
    _forwards = _forwards.where((f) => f.id != id).toList();
    notifyListeners();
  }

  void _updateStatus(String id, ForwardStatus status) {
    final index = _forwards.indexWhere((f) => f.id == id);
    if (index == -1) return;
    _forwards = [
      for (var i = 0; i < _forwards.length; i++)
        if (i == index) _forwards[i].copyWith(status: status) else _forwards[i],
    ];
    notifyListeners();
  }

  @override
  void dispose() {
    for (final id in _tunnels.keys.toList()) {
      _tunnelGenerations[id] = (_tunnelGenerations[id] ?? 0) + 1;
      _tunnels[id]?.close();
      _clients[id]?.close();
    }
    _tunnels.clear();
    _clients.clear();
    super.dispose();
  }
}
