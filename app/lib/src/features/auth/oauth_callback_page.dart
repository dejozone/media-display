import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/widgets/app_modal.dart';
import 'package:flutter/scheduler.dart';

class OAuthCallbackPage extends ConsumerStatefulWidget {
  const OAuthCallbackPage({
    super.key,
    required this.provider,
    required this.code,
    this.jwt,
    this.stateParam,
    this.errorParam,
    this.errorMessage,
  });

  final String provider;
  final String? code;
  final String? jwt;
  final String? stateParam;
  final String? errorParam;
  final String? errorMessage;

  @override
  ConsumerState<OAuthCallbackPage> createState() => _OAuthCallbackPageState();
}

class _OAuthCallbackPageState extends ConsumerState<OAuthCallbackPage> {
  String? _error;
  bool _done = false;
  bool _handledInitialError = false;

  @override
  void initState() {
    super.initState();
    _complete();
  }

  Future<void> _complete() async {
    // Handle server-redirected error payloads (e.g., spotify_identity_in_use) immediately.
    if (!_handledInitialError && widget.errorParam != null && widget.errorParam!.isNotEmpty) {
      _handledInitialError = true;
      // Defer until after first frame so dialog has a mounted context.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showErrorAndExit(widget.errorMessage ?? widget.errorParam!);
        }
      });
      return;
    }
    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      // Mirror web flow: always exchange code via API so identities/tokens are persisted.
      final code = widget.code;
      final state = widget.stateParam;

      if (code == null || code.isEmpty) {
        if (widget.jwt != null && widget.jwt!.isNotEmpty) {
          await authNotifier.setToken(widget.jwt!);
          if (!mounted) return;
          setState(() => _done = true);
          context.go('/home');
          return;
        }
        setState(() => _error = 'Missing code');
        return;
      }

      if (widget.provider == 'spotify' && (state == null || state.isEmpty)) {
        setState(() => _error = 'Missing state for Spotify login');
        return;
      }

      final auth = ref.read(authServiceProvider);
      await auth.completeOAuth(provider: widget.provider, code: code, state: state);
      await authNotifier.load();
      if (!mounted) return;
      setState(() => _done = true);
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      if (e is OAuthApiException && e.code == 'spotify_identity_in_use') {
        await _showErrorAndExit(e.message ?? 'This Spotify account is already linked to another user.');
        return;
      }
      setState(() => _error = e.toString());
    }
  }

  Future<void> _showErrorAndExit(String message) async {
    await showAppModal(
      context: context,
      title: 'Spotify account already linked',
      message: message,
      useRootNavigator: true,
    );
    if (!mounted) return;
    setState(() => _error = message);
    // Navigate back to account if possible, otherwise home/login fallback.
    final auth = ref.read(authStateProvider);
    final desired = await ref.read(authServiceProvider).consumePendingOauthRedirect();
    if (desired != null && desired.isNotEmpty) {
      context.go(desired);
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else if (auth.isAuthenticated) {
      context.go('/account');
    } else {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _error != null
                ? Text('Error: $_error', style: const TextStyle(color: Colors.red))
                : Text(_done ? 'Signed in! Redirecting…' : 'Completing sign-in…'),
          ),
        ),
      ),
    );
  }
}
