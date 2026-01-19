Future<T> withInsecureWs<T>(Future<T> Function() action, {required bool allowInsecure}) {
  return action();
}
