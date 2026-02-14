import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/services/auth_service.dart';
import 'package:media_display/src/services/auth_state.dart';
import 'package:media_display/src/services/token_storage.dart';
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
      if (kIsWeb) {
        final ok = await launchUrl(
          url,
          mode: LaunchMode.platformDefault,
          webOnlyWindowName: '_self',
        );
        if (!ok) {
          setState(() => _error = 'Failed to open browser for login');
          await _showFriendlyError();
        }
      } else {
        await Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => _InAppAuthScreen(initialUrl: url),
            fullscreenDialog: true,
          ),
        );
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
          Navigator.of(context, rootNavigator: true)
              .popUntil((route) => route.isFirst);
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

class _InAppAuthScreen extends ConsumerStatefulWidget {
  const _InAppAuthScreen({required this.initialUrl});

  final Uri initialUrl;

  @override
  ConsumerState<_InAppAuthScreen> createState() => _InAppAuthScreenState();
}

class _InAppAuthScreenState extends ConsumerState<_InAppAuthScreen> {
  late final WebViewController _controller;
  bool _completed = false;
  final _tokenStorage = TokenStorage();

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && _maybeHandleRedirect(uri)) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(widget.initialUrl);
  }

  @override
  void dispose() {
    _controller.clearCache();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authStateProvider, (prev, next) {
      if (!mounted || _completed) return;
      if (next.isAuthenticated) {
        _completed = true;
        final nav = Navigator.of(context, rootNavigator: true);
        nav.popUntil((route) => route.isFirst);
      }
    });

    final authState = ref.watch(authStateProvider);
    if (authState.isAuthenticated && !_completed) {
      _completed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final nav = Navigator.of(context, rootNavigator: true);
          nav.popUntil((route) => route.isFirst);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Sign In')),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }

  bool _maybeHandleRedirect(Uri uri) {
    final token = uri.queryParameters['jwt'] ?? uri.queryParameters['token'];
    if (token == null || token.isEmpty) return false;

    _completeWithToken(token);
    return true;
  }

  Future<void> _completeWithToken(String token) async {
    if (_completed) return;
    _completed = true;
    try {
      await _tokenStorage.save(token);
      await ref.read(authStateProvider.notifier).setToken(token);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
        );
      }
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
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
