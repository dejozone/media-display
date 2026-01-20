import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EnvConfig {
  EnvConfig({
    required this.apiBaseUrl,
    required this.eventsWsUrl,
    required this.flavor,
    required this.sslVerify,
    required this.eventsWsSslVerify,
    required this.wsRetryIntervalMs,
    required this.wsRetryActiveSeconds,
    required this.wsRetryCooldownSeconds,
    required this.wsRetryMaxTotalSeconds,
  });

  final String apiBaseUrl;
  final String eventsWsUrl;
  final String flavor;
  final bool sslVerify;
  final bool eventsWsSslVerify;
  final int wsRetryIntervalMs;
  final int wsRetryActiveSeconds;
  final int wsRetryCooldownSeconds;
  final int wsRetryMaxTotalSeconds;
}

final envConfigProvider = Provider<EnvConfig>((ref) {
  final api = dotenv.env['API_BASE_URL'] ?? 'http://localhost:5001';
  final ws = dotenv.env['EVENTS_WS_URL'] ?? 'ws://localhost:5002/events/media';
  final flavor = dotenv.env['FLAVOR'] ?? 'dev';
  final sslVerify = (dotenv.env['SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsSslVerify = (dotenv.env['EVENTS_WS_SSL_VERIFY'] ?? 'true').toLowerCase() == 'true';
  final wsRetryIntervalMs = int.tryParse(dotenv.env['WS_RETRY_INTERVAL_MS'] ?? '') ?? 2000;
  final wsRetryActiveSeconds = int.tryParse(dotenv.env['WS_RETRY_ACTIVE_SECONDS'] ?? '') ?? 60;
  final wsRetryCooldownSeconds = int.tryParse(dotenv.env['WS_RETRY_COOLDOWN_SECONDS'] ?? '') ?? 180;
  final wsRetryMaxTotalSeconds = int.tryParse(dotenv.env['WS_RETRY_MAX_TOTAL_SECONDS'] ?? '') ?? 1800;
  return EnvConfig(
    apiBaseUrl: api,
    eventsWsUrl: ws,
    flavor: flavor,
    sslVerify: sslVerify,
    eventsWsSslVerify: wsSslVerify,
    wsRetryIntervalMs: wsRetryIntervalMs,
    wsRetryActiveSeconds: wsRetryActiveSeconds,
    wsRetryCooldownSeconds: wsRetryCooldownSeconds,
    wsRetryMaxTotalSeconds: wsRetryMaxTotalSeconds,
  );
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'assets/env/.env');
}
