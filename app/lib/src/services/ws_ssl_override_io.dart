import 'dart:io';

class _InsecureOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

Future<T> withInsecureWs<T>(Future<T> Function() action, {required bool allowInsecure}) {
  if (!allowInsecure) return action();
  return HttpOverrides.runWithHttpOverrides(action, _InsecureOverrides());
}
