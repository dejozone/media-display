import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/config/env.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/widgets/app_modal.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _loading = false;
  String? _error;

  Future<void> _showFriendlyError() async {
    if (!mounted) return;
    await showAppModal(
      context: context,
      title: 'Login Unavailable',
      message:
          'We’re having trouble processing your request. Please try again soon.',
    );
  }

  Future<void> _startLogin(Future<Uri> Function() loader) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = await loader();
      if (!mounted) return;
      final ok = await launchUrl(
        url,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: kIsWeb ? '_self' : null,
      );
      if (!ok) {
        setState(() {
          _error = 'Failed to open browser for login';
        });
        await _showFriendlyError();
      }
    } catch (e) {
      setState(() {
        // _error = e.toString();
        _error = null; // Avoid showing raw error to users
      });
      await _showFriendlyError();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authServiceProvider);
    // final env = ref.watch(envConfigProvider);
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
                  const Text('Media Display Login',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  // Text('API: ${env.apiBaseUrl}'),
                  const SizedBox(height: 12),
                  _FocusableButton(
                    onPressed: _loading
                        ? null
                        : () => _startLogin(auth.getGoogleAuthUrl),
                    isOutlined: true,
                    child:
                        Text(_loading ? 'Redirecting…' : 'Login with Google'),
                  ),
                  const SizedBox(height: 12),
                  _FocusableButton(
                    onPressed: _loading
                        ? null
                        : () => _startLogin(auth.getSpotifyAuthUrl),
                    isOutlined: true,
                    child: Text(
                        _loading ? 'Redirecting…' : 'Enable Spotify (login)'),
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

class _FocusableButton extends StatefulWidget {
  const _FocusableButton({
    required this.child,
    this.onPressed,
    this.isOutlined = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool isOutlined;

  @override
  State<_FocusableButton> createState() => _FocusableButtonState();
}

class _FocusableButtonState extends State<_FocusableButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            widget.onPressed != null &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onPressed!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusableActionDetector(
        enabled: widget.onPressed != null,
        onShowFocusHighlight: (focused) {
          setState(() => _focused = focused);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? const Color(0xFF5AC8FA) : Colors.transparent,
              width: 2,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: const Color(0xFF5AC8FA).withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: widget.isOutlined
              ? OutlinedButton(
                  onPressed: widget.onPressed,
                  child: widget.child,
                )
              : ElevatedButton(
                  onPressed: widget.onPressed,
                  child: widget.child,
                ),
        ),
      ),
    );
  }
}
