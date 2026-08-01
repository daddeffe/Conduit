import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/port_forward/domain/forward_tunnel.dart';
import 'package:conduit/features/port_forward/domain/saved_persistent_forward.dart';
import 'package:conduit/features/port_forward/presentation/persistent_forward_controller.dart';
import 'package:flutter/material.dart';

class PersistentForwardsPage extends StatefulWidget {
  const PersistentForwardsPage({
    required this.controller,
    required this.hosts,
    this.initialHostId,
    super.key,
  });

  final PersistentForwardController controller;
  final List<SavedHost> hosts;
  final String? initialHostId;

  @override
  State<PersistentForwardsPage> createState() => _PersistentForwardsPageState();
}

class _PersistentForwardsPageState extends State<PersistentForwardsPage> {
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    if (widget.initialHostId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAddDialog(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Persistent forwards'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add forward',
            onPressed: () => _showAddDialog(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final forwards = widget.controller.forwards;
          if (forwards.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 48,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No persistent forwards',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add a forward and it will be saved for future sessions.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => _showAddDialog(context),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Add forward'),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: forwards.length,
            itemBuilder: (context, index) {
              final forward = forwards[index];
              final isExpanded = _expandedId == forward.id;
              return _ForwardTile(
                forward: forward,
                expanded: isExpanded,
                onTap: () {
                  setState(() {
                    _expandedId = isExpanded ? null : forward.id;
                  });
                },
                onStart: () => widget.controller.startForward(forward),
                onStop: () => widget.controller.stopForward(forward.id),
                onDelete: () => _confirmDelete(context, forward),
                tunnel: widget.controller.tunnelFor(forward.id),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final result = await showDialog<FormResult>(
      context: context,
      builder: (context) => _AddForwardDialog(
        hosts: widget.hosts,
        controller: widget.controller,
        initialHostId: widget.initialHostId,
      ),
    );
    if (result == null || !mounted) return;

    final forward = SavedPersistentForward.create(
      name: result.name,
      localPort: result.localPort,
      remoteHost: result.remoteHost,
      remotePort: result.remotePort,
      hostId: result.hostId,
      autoReconnect: result.autoReconnect,
    );

    try {
      await widget.controller.startForward(forward);
    } catch (_) {
      // Forward start may fail; still save the config
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    SavedPersistentForward forward,
  ) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forward?'),
        content: Text('Remove "${forward.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete ?? false) {
      widget.controller.removeForward(forward.id);
    }
  }
}

class _ForwardTile extends StatelessWidget {
  const _ForwardTile({
    required this.forward,
    required this.expanded,
    required this.onTap,
    required this.onStart,
    required this.onStop,
    required this.onDelete,
    this.tunnel,
  });

  final SavedPersistentForward forward;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onDelete;
  final ForwardTunnel? tunnel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final statusColor = switch (forward.status) {
      ForwardStatus.idle => colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      ForwardStatus.connecting => const Color(0xFFF1C40F),
      ForwardStatus.active => const Color(0xFF2ECC71),
      ForwardStatus.error => const Color(0xFFE74C3C),
    };

    final label = '127.0.0.1:${forward.localPort} → '
        '${forward.remoteHost}:${forward.remotePort}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: forward.status == ForwardStatus.active
                    ? const Color(0xFF2ECC71).withValues(alpha: 0.45)
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.only(right: 10),
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              forward.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (forward.status == ForwardStatus.active)
                        IconButton(
                          icon: Icon(Icons.stop_circle_outlined,
                              size: 20, color: colorScheme.error),
                          onPressed: onStop,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: 'Stop',
                        )
                      else if (forward.status == ForwardStatus.idle ||
                          forward.status == ForwardStatus.error)
                        IconButton(
                          icon: Icon(Icons.play_circle_outline,
                              size: 20, color: colorScheme.primary),
                          onPressed: onStart,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: 'Start',
                        )
                      else
                        const SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ),
                      IconButton(
                        icon: Icon(Icons.delete_outline_rounded,
                            size: 18, color: colorScheme.error),
                        onPressed: onDelete,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
                if (expanded && tunnel != null)
                  _TunnelDetails(
                    tunnel: tunnel!,
                    colorScheme: colorScheme,
                    theme: theme,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TunnelDetails extends StatelessWidget {
  const _TunnelDetails({
    required this.tunnel,
    required this.colorScheme,
    required this.theme,
  });

  final ForwardTunnel tunnel;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          Text(
            'Tunnel active',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Listening on 127.0.0.1:${tunnel.localPort}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddForwardDialog extends StatefulWidget {
  const _AddForwardDialog({required this.hosts, required this.controller, this.initialHostId});

  final List<SavedHost> hosts;
  final PersistentForwardController controller;
  final String? initialHostId;

  @override
  State<_AddForwardDialog> createState() => _AddForwardDialogState();
}

class _AddForwardDialogState extends State<_AddForwardDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _localPortController = TextEditingController();
  final _remoteHostController = TextEditingController(text: '127.0.0.1');
  final _remotePortController = TextEditingController();
  bool _localPortAutoMirror = true;
  SavedHost? _selectedHost;
  bool _autoReconnect = false;
  bool _remoteHostDefault = true;
  final _remoteHostFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.initialHostId != null) {
      final host = widget.hosts.cast<SavedHost?>().firstWhere(
        (h) => h?.id == widget.initialHostId,
        orElse: () => null,
      );
      if (host != null) {
        _selectedHost = host;
      }
    }
    _remotePortController.addListener(_onRemotePortChanged);
    _remoteHostFocusNode.addListener(_onRemoteHostFocusChanged);
  }

  @override
  void dispose() {
    _remotePortController.removeListener(_onRemotePortChanged);
    _nameController.dispose();
    _localPortController.dispose();
    _remoteHostController.dispose();
    _remoteHostFocusNode.dispose();
    _remotePortController.dispose();
    super.dispose();
  }

  void _onRemoteHostFocusChanged() {
    if (!_remoteHostFocusNode.hasFocus && _remoteHostController.text.trim().isEmpty) {
      _remoteHostController.text = '127.0.0.1';
      _remoteHostDefault = true;
    }
  }

  void _onRemotePortChanged() {
    if (!_localPortAutoMirror) return;
    final remoteText = _remotePortController.text.trim();
    if (remoteText.isNotEmpty && int.tryParse(remoteText) != null) {
      _localPortController.text = remoteText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('Add persistent forward'),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: ListView(
            shrinkWrap: true,
            children: [
              DropdownButtonFormField<SavedHost>(
                value: _selectedHost,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  isDense: true,
                ),
                isExpanded: true,
                items: [
                  for (final host in widget.hosts)
                    DropdownMenuItem(
                      value: host,
                      child: Text(
                        host.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (host) =>
                    setState(() => _selectedHost = host),
                validator: (v) => v == null ? 'Select a host' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Optional - auto-generated',
                  isDense: true,
                ),
                validator: (v) {
                    if (v != null && v.trim().isNotEmpty && widget.controller.hasForwardWithName(v.trim())) {
                      return 'A forward with this name already exists';
                    }
                    return null;
                  },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _localPortController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Local port',
                        hintText: 'Same as remote',
                        hintStyle: TextStyle(color: Color(0xFF9E9E9E)),
                        isDense: true,
                      ),
                      onChanged: (_) {
                        _localPortAutoMirror = false;
                      },
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        final p = int.tryParse(v.trim());
                        if (p == null || p < 1 || p > 65535) {
                          return 'Invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded,
                      size: 16, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _remoteHostController,
                      focusNode: _remoteHostFocusNode,
                      style: TextStyle(
                        color: _remoteHostDefault
                            ? Color(0xFF9E9E9E)
                            : null,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Remote host',
                        isDense: true,
                      ),
                      onTap: () {
                        if (_remoteHostDefault) {
                          _remoteHostController.clear();
                          _remoteHostDefault = false;
                        }
                      },
                      validator: (v) => null,
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
                        if (v == null || v.trim().isEmpty) {
                          return 'Required';
                        }
                        final p = int.tryParse(v.trim());
                        if (p == null || p < 1 || p > 65535) {
                          return 'Invalid';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _autoReconnect,
                onChanged: (v) =>
                    setState(() => _autoReconnect = v ?? true),
                title: const Text('Auto-reconnect on app start'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final remoteHost = _remoteHostController.text.trim();
            final remotePort =
                int.parse(_remotePortController.text.trim());
            final localPort =
                int.parse(_localPortController.text.trim());

            final resolvedLocalPort = _localPortController.text.trim().isEmpty
                ? remotePort
                : int.parse(_localPortController.text.trim());
            final resolvedRemoteHost = _remoteHostController.text.trim().isEmpty
                ? '127.0.0.1'
                : _remoteHostController.text.trim();
            final resolvedName = _nameController.text.trim().isNotEmpty
                ? _nameController.text.trim()
                : '${_selectedHost!.name}:$remotePort';

            Navigator.of(context).pop(
              FormResult(
                name: resolvedName,
                localPort: resolvedLocalPort,
                remoteHost: resolvedRemoteHost,
                remotePort: remotePort,
                hostId: _selectedHost!.id,
                autoReconnect: _autoReconnect,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class FormResult {
  FormResult({
    required this.name,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.hostId,
    required this.autoReconnect,
  });

  final String name;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final String hostId;
  final bool autoReconnect;
}
