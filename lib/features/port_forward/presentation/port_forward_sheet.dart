import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/data/ssh_error_formatter.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

class PortForwardSheet extends StatefulWidget {
  const PortForwardSheet({
    required this.host,
    required this.hostKeyVerifier,
    super.key,
  });

  final SavedHost host;
  final HostKeyVerifier hostKeyVerifier;

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
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _connect();
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
                    _forwardForm(theme, colorScheme),
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

  Widget _forwardForm(ThemeData theme, ColorScheme colorScheme) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'New forward',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
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
