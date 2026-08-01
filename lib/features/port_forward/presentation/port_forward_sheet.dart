import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/port_forward/domain/port_forward_config_repository.dart';
import 'package:conduit/features/port_forward/domain/saved_port_forward_config.dart';
import 'package:conduit/features/port_forward/domain/saved_persistent_forward.dart';
import 'package:conduit/features/port_forward/presentation/persistent_forward_controller.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/data/ssh_error_formatter.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

enum _PortStatus { unknown, open, closed }

class PortForwardSheet extends StatefulWidget {
  const PortForwardSheet({
    required this.host,
    required this.hostKeyVerifier,
    required this.configRepository,
    this.persistentForwardController,
    super.key,
  });

  final SavedHost host;
  final HostKeyVerifier hostKeyVerifier;
  final PortForwardConfigRepository configRepository;
  final PersistentForwardController? persistentForwardController;

  @override
  State<PortForwardSheet> createState() => _PortForwardSheetState();
}

class _PortForwardSheetState extends State<PortForwardSheet> {
  SSHClient? _client;
  bool _connecting = false;
  String? _error;
  final _entries = <_ForwardEntry>[];
  final _localPortController = TextEditingController();
  final _remoteHostController = TextEditingController();
  final _remotePortController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<SavedPortForwardConfig> _savedConfigs = [];
  final _configPortStatus = <String, _PortStatus>{};
  bool _loadingConfigs = false;

  @override
  void initState() {
    super.initState();
    _connect();
    _loadConfigs();
  }

  void _saveActiveForward() {
    if (_entries.isEmpty) return;
    final entry = _entries.first;
    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : '${widget.host.name}:${entry.localPort}→${entry.remoteHost}:${entry.remotePort}';
    final forward = SavedPersistentForward.create(
      name: name,
      localPort: entry.localPort,
      remoteHost: entry.remoteHost,
      remotePort: entry.remotePort,
      hostId: widget.host.id,
      autoReconnect: true,
    );
    widget.persistentForwardController!.addAndSaveForward(forward);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Forward saved as persistent')),
    );
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      unawaited(entry.server.close());
      for (final pipe in entry.pipes) {
        unawaited(pipe.channel.close());
      }
    }
    _client?.close();
    _localPortController.dispose();
    _remoteHostController.dispose();
    _remotePortController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final factory = SshClientFactory(widget.hostKeyVerifier);
      final client = await factory.connect(widget.host);
      if (!mounted) {
        client.close();
        return;
      }
      setState(() {
        _client = client;
        _connecting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = describeSshConnectionError(error);
      });
    }
  }

  Future<void> _loadConfigs() async {
    setState(() => _loadingConfigs = true);
    try {
      final configs = await widget.configRepository.loadConfigs();
      if (!mounted) return;
      setState(() {
        _savedConfigs = configs;
        _loadingConfigs = false;
      });
      for (final config in configs) {
        unawaited(_checkPortStatus(config));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingConfigs = false);
    }
  }

  Future<void> _checkPortStatus(SavedPortForwardConfig config) async {
    setState(() => _configPortStatus[config.id] = _PortStatus.unknown);
    try {
      final socket = await Socket.connect(
        config.remoteHost,
        config.remotePort,
        timeout: const Duration(seconds: 3),
      );
      unawaited(socket.close());
      if (!mounted) return;
      setState(() => _configPortStatus[config.id] = _PortStatus.open);
    } catch (_) {
      if (!mounted) return;
      setState(() => _configPortStatus[config.id] = _PortStatus.closed);
    }
  }

  Future<void> _saveCurrentConfig() async {
    final remoteHost = _remoteHostController.text.trim();
    final remotePortText = _remotePortController.text.trim();
    if (remoteHost.isEmpty || remotePortText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill remote host and port first')),
      );
      return;
    }
    final remotePort = int.tryParse(remotePortText);
    if (remotePort == null || remotePort < 1 || remotePort > 65535) return;

    final localPortText = _localPortController.text.trim();
    final localPort =
        localPortText.isNotEmpty ? int.tryParse(localPortText) : null;

    String? name;
    if (_nameController.text.trim().isNotEmpty) {
      name = _nameController.text.trim();
    }

    final config = SavedPortForwardConfig.create(
      name: name,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
    );

    await widget.configRepository.addConfig(config);
    setState(() => _savedConfigs.add(config));
    _nameController.clear();
    unawaited(_checkPortStatus(config));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuration saved')),
    );
  }

  Future<void> _deleteConfig(SavedPortForwardConfig config) async {
    await widget.configRepository.removeConfig(config.id);
    setState(() {
      _savedConfigs.removeWhere((c) => c.id == config.id);
      _configPortStatus.remove(config.id);
    });
  }

  void _applyConfig(SavedPortForwardConfig config) {
    _localPortController.text =
        config.localPort != null ? config.localPort.toString() : '';
    _remoteHostController.text = config.remoteHost;
    _remotePortController.text = config.remotePort.toString();
  }

  Future<void> _addForward() async {
    if (!_formKey.currentState!.validate()) return;
    final remoteHost = _remoteHostController.text.trim();
    final remotePort = int.parse(_remotePortController.text.trim());
    final localPortText = _localPortController.text.trim();
    final requestedLocalPort =
        localPortText.isNotEmpty ? int.tryParse(localPortText) : null;

    final client = _client;
    if (client == null) return;

    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        requestedLocalPort ?? 0,
      );

      _localPortController.clear();
      _remoteHostController.clear();
      _remotePortController.clear();

      final entry = _ForwardEntry(
        server: server,
        localPort: server.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
      setState(() => _entries.add(entry));

      server.listen(
        (socket) async {
          try {
            final channel = await client.forwardLocal(remoteHost, remotePort);
            final pipe = _Pipe(channel: channel, socket: socket);
            entry.pipes.add(pipe);
            _pipeBidirectional(entry, pipe);
          } catch (_) {
            unawaited(socket.close());
          }
        },
        onError: (_) => _removeForward(entry),
        cancelOnError: false,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Forward failed: $error')),
      );
    }
  }

  void _pipeBidirectional(_ForwardEntry entry, _Pipe pipe) {
    final sub1 = pipe.channel.stream.listen(
      (data) {
        pipe.socket.add(data);
      },
      onError: (_) => _cleanupPipe(entry, pipe),
      onDone: () => _cleanupPipe(entry, pipe),
      cancelOnError: false,
    );
    final sub2 = pipe.socket.listen(
      (data) {
        pipe.channel.sink.add(data);
      },
      onError: (_) => _cleanupPipe(entry, pipe),
      onDone: () => _cleanupPipe(entry, pipe),
      cancelOnError: false,
    );

    pipe.subscription1 = sub1;
    pipe.subscription2 = sub2;
  }

  void _cleanupPipe(_ForwardEntry entry, _Pipe pipe) {
    unawaited(pipe.subscription1?.cancel() ?? Future<void>.value());
    unawaited(pipe.subscription2?.cancel() ?? Future<void>.value());
    unawaited(pipe.channel.close());
    unawaited(pipe.socket.close());
    entry.pipes.remove(pipe);
    if (!mounted) return;
    setState(() {});
  }

  void _removeForward(_ForwardEntry entry) {
    unawaited(entry.server.close());
    for (final pipe in List.of(entry.pipes)) {
      _cleanupPipe(entry, pipe);
    }
    setState(() => _entries.remove(entry));
  }

  Future<void> _disconnect() async {
    for (final entry in _entries) {
      unawaited(entry.server.close());
      for (final pipe in entry.pipes) {
        unawaited(pipe.channel.close());
        unawaited(pipe.socket.close());
      }
    }
    _entries.clear();
    _client?.close();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            _handleBar(colorScheme),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  _header(theme, colorScheme),
                  const SizedBox(height: 16),
                  if (_connecting) ...[
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                    Center(
                      child: Text(
                        'Connecting to ${widget.host.endpoint}...',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ] else if (_error != null) ...[
                    _errorBanner(theme, colorScheme),
                  ] else if (_client != null) ...[
                    _savedConfigsSection(theme, colorScheme),
                    const SizedBox(height: 16),
                    _forwardForm(theme, colorScheme),

                    const SizedBox(height: 8),
                    if (_entries.isNotEmpty && widget.persistentForwardController != null) ...[
                      FilledButton.icon(
                        onPressed: _saveActiveForward,
                        icon: const Icon(Icons.save_rounded, size: 18),
                        label: const Text('Save as persistent'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    const SizedBox(height: 16),
                    if (_entries.isNotEmpty) ...[
                      Text(
                        'Active forwards',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final entry in _entries)
                        _forwardTile(entry, colorScheme, theme),
                    ] else
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'No active port forwards',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: _disconnect,
                      icon: const Icon(Icons.power_settings_new_rounded),
                      label: const Text('Disconnect'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _handleBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme colorScheme) {
    return Row(
      children: [
        Icon(Icons.swap_horiz_rounded, color: colorScheme.primary, size: 28),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Port forward',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              widget.host.endpoint,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _errorBanner(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: colorScheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _portStatusDot(_PortStatus status, ColorScheme colorScheme) {
    final color = switch (status) {
      _PortStatus.open => const Color(0xFF2ECC71),
      _PortStatus.closed => const Color(0xFFE74C3C),
      _PortStatus.unknown => colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
    };
    return Container(
      width: 10,
      height: 10,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusLabel(_PortStatus status) {
    return switch (status) {
      _PortStatus.open => 'Port open',
      _PortStatus.closed => 'Port closed',
      _PortStatus.unknown => 'Not checked',
    };
  }

  Widget _savedConfigsSection(ThemeData theme, ColorScheme colorScheme) {
    if (_loadingConfigs) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
      );
    }

    if (_savedConfigs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Saved configs',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_savedConfigs.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final config in _savedConfigs)
          _savedConfigTile(config, theme, colorScheme),
      ],
    );
  }

  Widget _savedConfigTile(
    SavedPortForwardConfig config,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final status = _configPortStatus[config.id] ?? _PortStatus.unknown;
    final label = config.name.isNotEmpty
        ? config.name
        : '${config.remoteHost}:${config.remotePort}';

    final details = StringBuffer();
    if (config.localPort != null) {
      details.write('127.0.0.1:${config.localPort} → ');
    }
    details.write('${config.remoteHost}:${config.remotePort}');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _applyConfig(config),
          child: Row(
            children: [
              _portStatusDot(status, colorScheme),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details.toString(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(status),
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: colorScheme.error),
                onPressed: () => _deleteConfig(config),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Delete config',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _forwardForm(ThemeData theme, ColorScheme colorScheme) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'New forward',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 32,
                child: FilledButton.tonalIcon(
                  onPressed: _saveCurrentConfig,
                  icon: const Icon(Icons.bookmark_add_rounded, size: 16),
                  label: const Text('Save', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'My database tunnel',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _localPortController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Local port',
                    hintText: 'random',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded,
                  size: 18, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _remoteHostController,
                  decoration: const InputDecoration(
                    labelText: 'Remote host',
                    hintText: 'localhost',
                    isDense: true,
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _remotePortController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Remote port',
                    isDense: true,
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Required';
                    final p = int.tryParse(v.trim());
                    if (p == null || p < 1 || p > 65535) return 'Invalid';
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _addForward,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add forward'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forwardTile(
    _ForwardEntry entry,
    ColorScheme colorScheme,
    ThemeData theme,
  ) {
    final activeConnections = entry.pipes.length;
    final label =
        '127.0.0.1:${entry.localPort} → ${entry.remoteHost}:${entry.remotePort}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.link_rounded, size: 16, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  if (activeConnections > 0)
                    Text(
                      '$activeConnections active connection${activeConnections == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.stop_circle_outlined,
                  size: 20, color: colorScheme.error),
              onPressed: () => _removeForward(entry),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Stop forward',
            ),
          ],
        ),
      ),
    );
  }
}

class _ForwardEntry {
  _ForwardEntry({
    required this.server,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  final ServerSocket server;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final List<_Pipe> pipes = [];
}

class _Pipe {
  _Pipe({required this.channel, required this.socket});

  final SSHForwardChannel channel;
  final Socket socket;
  StreamSubscription<Uint8List>? subscription1;
  StreamSubscription<List<int>>? subscription2;
}
