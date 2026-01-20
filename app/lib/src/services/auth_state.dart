import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/token_storage.dart';

class AuthState {
  const AuthState({this.token, this.loading = true});
  final String? token;
  final bool loading;
  bool get isAuthenticated => token != null && token!.isNotEmpty;
}

class AuthNotifier extends Notifier<AuthState> {
  late final TokenStorage _storage = TokenStorage();

  @override
  AuthState build() {
    // Kick off async load; mark loading until token is read.
    _load();
    return const AuthState(loading: true);
  }

  Future<void> _load() async {
    final tok = await _storage.load();
    state = AuthState(token: tok, loading: false);
  }

  Future<void> load() async {
    await _load();
  }

  Future<void> setToken(String token) async {
    await _storage.save(token);
    state = AuthState(token: token, loading: false);
  }

  Future<void> clear() async {
    await _storage.clear();
    state = const AuthState(token: null, loading: false);
  }
}

final authStateProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
