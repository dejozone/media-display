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
    this.stateParam,
  });

  final String provider;
  final String? code;
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
    if (widget.code == null || widget.code!.isEmpty) {
      setState(() => _error = 'Missing code');
      return;
    }
    try {
      final auth = ref.read(authServiceProvider);
      await auth.completeOAuth(provider: widget.provider, code: widget.code!, state: widget.stateParam);
      await ref.read(authStateProvider.notifier).load();
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
