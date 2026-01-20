import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_display/src/features/auth/login_page.dart';
import 'package:media_display/src/features/auth/oauth_callback_page.dart';
import 'package:media_display/src/features/home/home_page.dart';
import 'package:media_display/src/features/account/account_settings_page.dart';
import 'package:media_display/src/services/auth_state.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.onDispose(refresh.dispose);
  ref.listen<AuthState>(authStateProvider, (_, __) => refresh.value++);
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.loading) return null; // avoid redirects until token load finishes
      final loggedIn = auth.isAuthenticated;
      final loggingIn = state.uri.path == '/login';
      final oauthFlow = state.uri.path.startsWith('/oauth/');
      final oauthHasError = oauthFlow && state.uri.queryParameters.containsKey('error');

      if (!loggedIn && !(loggingIn || oauthFlow)) {
        return '/login';
      }
      if (loggedIn && (loggingIn || (oauthFlow && !oauthHasError))) {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: '/oauth/:provider/callback',
        builder: (context, state) {
          final provider = state.pathParameters['provider'] ?? '';
          final code = state.uri.queryParameters['code'];
          final jwt = state.uri.queryParameters['jwt'];
          final oauthState = state.uri.queryParameters['state'];
          final error = state.uri.queryParameters['error'];
          final message = state.uri.queryParameters['message'];
          return OAuthCallbackPage(
            provider: provider,
            code: code,
            jwt: jwt,
            stateParam: oauthState,
            errorParam: error,
            errorMessage: message,
          );
        },
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) => const AccountSettingsPage(),
      ),
    ],
  );
});
