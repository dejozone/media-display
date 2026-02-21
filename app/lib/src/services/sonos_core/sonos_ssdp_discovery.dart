import 'dart:async';

abstract class SonosSsdpDiscoveryAdapter {
  Future<List<String>> discoverHosts({
    required Duration timeout,
    required int maxHosts,
  });
}

class SonosSsdpDiscovery {
  const SonosSsdpDiscovery(this._adapter);

  final SonosSsdpDiscoveryAdapter _adapter;

  Future<T?> discoverCoordinator<T>({
    required Duration timeout,
    required int maxHosts,
    required Future<T?> Function(String host) evaluateHost,
  }) async {
    final hosts = await _adapter.discoverHosts(
      timeout: timeout,
      maxHosts: maxHosts,
    );

    for (final host in hosts) {
      final result = await evaluateHost(host);
      if (result != null) {
        return result;
      }
    }

    return null;
  }
}
