import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_display/src/services/token_storage.dart';

class AuthState {
  const AuthState({this.token});
  final String? token;
  bool get isAuthenticated => token != null && token!.isNotEmpty;
}

class AuthNotifier extends Notifier<AuthState> {
  late final TokenStorage _storage = TokenStorage();

  @override
  AuthState build() {
    // Kick off async load and keep initial unauthenticated state.
    _load();
    return const AuthState();
  }

  Future<void> _load() async {
    final tok = await _storage.load();
    state = AuthState(token: tok);
  }

  Future<void> load() async {
    await _load();
  }

  Future<void> setToken(String token) async {
    await _storage.save(token);
    state = AuthState(token: token);
  }

  Future<void> clear() async {
    await _storage.clear();
    state = const AuthState(token: null);
  }
}

final authStateProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
