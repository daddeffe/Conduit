import 'dart:async';

import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/app_lock/data/local_app_authenticator.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/app_lock/presentation/lock_page.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/data/secure_saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/port_forward/data/secure_port_forward_config_repository.dart';
import 'package:conduit/features/port_forward/domain/port_forward_config_repository.dart';
import 'package:conduit/features/port_forward/presentation/persistent_forward_controller.dart';
import 'package:conduit/features/local_shell/data/local_terminal_repository.dart';
import 'package:conduit/features/local_shell/local_shell_licenses.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/sftp/data/dart_ssh_sftp_repository.dart';
import 'package:conduit/features/sftp/data/file_picker_file_export.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/terminal/data/connectivity_plus_network.dart';
import 'package:conduit/features/terminal/data/dart_ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/data/routing_terminal_repository.dart';
import 'package:conduit/features/terminal/data/secure_host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_background_keepalive.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerLocalShellLicenses();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  const secureStorage = FlutterSecureStorage();
  final themeController = ThemeController(
    const ThemePreferencesRepository(secureStorage),
  );
  final lockController = AppLockController(LocalAppAuthenticator());
  final hostsRepository = SecureSavedHostsRepository(secureStorage);
  final hostsController = HostsController(hostsRepository);
  final promptCoordinator = HostKeyPromptCoordinator();
  final hostKeyVerifier = SecureHostKeyVerifier(
    secureStorage,
    promptCoordinator,
  );
  final localShellController = LocalShellController();
  final terminalRepository = RoutingTerminalRepository(
    ssh: DartSshTerminalRepository(hostKeyVerifier),
    mosh: MoshTerminalRepository(hostKeyVerifier),
    local: LocalTerminalRepository(
      resolveLaunch: localShellController.requireLaunch,
    ),
  );
  final workspaceController = TerminalWorkspaceController(
    terminalRepository,
    ConnectivityPlusNetwork(),
  );
  final sftpRepository = DartSshSftpRepository(hostKeyVerifier);
  final portForwardConfigRepository =
      SecurePortForwardConfigRepository(secureStorage);
  final persistentForwardController = PersistentForwardController(
    hostsRepository: hostsRepository,
    clientFactory: SshClientFactory(hostKeyVerifier),
    hostResolver: (hostId) {
      try {
        return hostsController.hosts.firstWhere((h) => h.id == hostId);
      } catch (_) {
        return null;
      }
    },
  );
  final backupService = AppBackupService(
    hostsController: hostsController,
    themeController: themeController,
    hostKeyVerifier: hostKeyVerifier,
  );
  const fileExport = FilePickerFileExport();

  unawaited(themeController.load());
  unawaited(persistentForwardController.load());

  runApp(
    ConduitApp(
      themeController: themeController,
      lockController: lockController,
      hostsController: hostsController,
      terminalRepository: terminalRepository,
      workspaceController: workspaceController,
      localShellController: localShellController,
      hostKeyVerifier: hostKeyVerifier,
      promptCoordinator: promptCoordinator,
      sftpRepository: sftpRepository,
      backupService: backupService,
      fileExport: fileExport,
      portForwardConfigRepository: portForwardConfigRepository,
      persistentForwardController: persistentForwardController,
    ),
  );
}

class ConduitApp extends StatefulWidget {
  const ConduitApp({
    required this.themeController,
    required this.lockController,
    required this.hostsController,
    required this.terminalRepository,
    required this.workspaceController,
    required this.localShellController,
    required this.hostKeyVerifier,
    required this.promptCoordinator,
    required this.sftpRepository,
    required this.backupService,
    required this.fileExport,
    required this.portForwardConfigRepository,
    required this.persistentForwardController,
    super.key,
  });

  final ThemeController themeController;
  final AppLockController lockController;
  final HostsController hostsController;
  final SshTerminalRepository terminalRepository;
  final TerminalWorkspaceController workspaceController;
  final LocalShellController localShellController;
  final HostKeyVerifier hostKeyVerifier;
  final HostKeyPromptCoordinator promptCoordinator;
  final SftpRepository sftpRepository;
  final AppBackupService backupService;
  final FileExport fileExport;
  final PortForwardConfigRepository portForwardConfigRepository;
  final PersistentForwardController persistentForwardController;

  @override
  State<ConduitApp> createState() => _ConduitAppState();
}

class _ConduitAppState extends State<ConduitApp> with WidgetsBindingObserver {
  final _backgroundKeepalive = const TerminalBackgroundKeepalive();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _keepaliveRunning = false;
  int _keepaliveSessionCount = 0;
  bool _notificationPermissionRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.workspaceController.addListener(_syncBackgroundKeepalive);
    widget.persistentForwardController.addListener(_syncBackgroundKeepalive);
    widget.themeController.addListener(_syncTerminalPreferences);
    _syncTerminalPreferences();
  }

  void _syncTerminalPreferences() {
    widget.workspaceController.setEnterSequence(
      widget.themeController.terminalEnterSequence,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncBackgroundKeepalive();

    if (state == AppLifecycleState.resumed) {
      for (final session in widget.workspaceController.sessions) {
        session.forceResize();
      }
    }
  }

  void _syncBackgroundKeepalive() {
    final sessionCount = widget.workspaceController.liveSessionCount;
    final forwardCount = widget.persistentForwardController.activeForwardCount;
    final totalCount = sessionCount + forwardCount;
    _maybeRequestNotificationPermission(totalCount);
    final shouldRun =
        totalCount > 0 &&
        (_lifecycleState == AppLifecycleState.hidden ||
            _lifecycleState == AppLifecycleState.paused);

    if (shouldRun == _keepaliveRunning &&
        (!shouldRun || totalCount == _keepaliveSessionCount)) {
      return;
    }

    _keepaliveRunning = shouldRun;
    _keepaliveSessionCount = shouldRun ? totalCount : 0;
    unawaited(
      (shouldRun
              ? _backgroundKeepalive.start(sessionCount: sessionCount, forwardCount: forwardCount)
              : _backgroundKeepalive.stop())
          .catchError((_) {
            _keepaliveRunning = !shouldRun;
            _keepaliveSessionCount = 0;
          }),
    );
  }

  void _maybeRequestNotificationPermission(int sessionCount) {
    if (_notificationPermissionRequested ||
        sessionCount == 0 ||
        _lifecycleState != AppLifecycleState.resumed ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _notificationPermissionRequested = true;
    unawaited(
      _backgroundKeepalive.requestNotificationPermission().catchError((_) {}),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.workspaceController.removeListener(_syncBackgroundKeepalive);
    widget.persistentForwardController.removeListener(_syncBackgroundKeepalive);
    widget.themeController.removeListener(_syncTerminalPreferences);
    unawaited(_backgroundKeepalive.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'Conduit',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(
            brightness: Brightness.light,
            palette: widget.themeController.palette,
          ),
          darkTheme: AppTheme.build(
            brightness: Brightness.dark,
            palette: widget.themeController.palette,
          ),
          themeMode: widget.themeController.themeMode,
          builder: (context, child) {
            final overlayStyle = AppTheme.systemUiOverlayStyle(
              Theme.of(context).brightness,
            );
            SystemChrome.setSystemUIOverlayStyle(overlayStyle);
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlayStyle,
              child: Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  AndroidThreeButtonNavigationBackground(
                    color: Theme.of(context).scaffoldBackgroundColor,
                  ),
                ],
              ),
            );
          },
          home: ListenableBuilder(
            listenable: widget.lockController,
            builder: (context, _) {
              if (!widget.lockController.isUnlocked) {
                return LockPage(
                  controller: widget.lockController,
                  themeController: widget.themeController,
                );
              }

              return HostsPage(
                hostsController: widget.hostsController,
                lockController: widget.lockController,
                terminalRepository: widget.terminalRepository,
                workspaceController: widget.workspaceController,
                localShellController: widget.localShellController,
                themeController: widget.themeController,
                hostKeyVerifier: widget.hostKeyVerifier,
                promptCoordinator: widget.promptCoordinator,
                sftpRepository: widget.sftpRepository,
                backupService: widget.backupService,
                fileExport: widget.fileExport,
                portForwardConfigRepository:
                    widget.portForwardConfigRepository,
                persistentForwardController:
                    widget.persistentForwardController,
              );
            },
          ),
        );
      },
    );
  }
}
