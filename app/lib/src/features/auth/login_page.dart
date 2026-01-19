import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';
import '../../services/auth_service.dart';
import '../../config/env.dart';
import '../../services/auth_state.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _loading = false;
  String? _error;

  Future<void> _startLogin(Future<Uri> Function() loader) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = await loader();
      if (!mounted) return;
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok) {
        setState(() {
          _error = 'Failed to open browser for login';
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authServiceProvider);
    final env = ref.watch(envConfigProvider);
    final authState = ref.watch(authStateProvider);

    if (authState.isAuthenticated) {
      // If already logged in, go to home
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.go('/home');
        }
      });
    }

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Media Display Login', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text('API: ${env.apiBaseUrl}'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loading ? null : () => _startLogin(auth.getGoogleAuthUrl),
                    child: Text(_loading ? 'Redirecting…' : 'Login with Google'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _loading ? null : () => _startLogin(auth.getSpotifyAuthUrl),
                    child: Text(_loading ? 'Redirecting…' : 'Enable Spotify (login)'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
