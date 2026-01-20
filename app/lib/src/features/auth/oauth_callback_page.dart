import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/services/auth_state.dart';

class OAuthCallbackPage extends ConsumerStatefulWidget {
  const OAuthCallbackPage({
    super.key,
    required this.provider,
    required this.code,
    this.jwt,
    this.stateParam,
  });

  final String provider;
  final String? code;
  final String? jwt;
  final String? stateParam;

  @override
  ConsumerState<OAuthCallbackPage> createState() => _OAuthCallbackPageState();
}

class _OAuthCallbackPageState extends ConsumerState<OAuthCallbackPage> {
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _complete();
  }

  Future<void> _complete() async {
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
      setState(() => _error = e.toString());
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
