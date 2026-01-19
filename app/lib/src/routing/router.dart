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
      final loggedIn = ref.read(authStateProvider).isAuthenticated;
      final loggingIn = state.uri.path == '/login';
      final oauthFlow = state.uri.path.startsWith('/oauth/');

      if (!loggedIn && !(loggingIn || oauthFlow)) {
        return '/login';
      }
      if (loggedIn && (loggingIn || oauthFlow)) {
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
          return OAuthCallbackPage(
            provider: provider,
            code: code,
            jwt: jwt,
            stateParam: oauthState,
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
