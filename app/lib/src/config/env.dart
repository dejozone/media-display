import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EnvConfig {
  EnvConfig({
    required this.apiBaseUrl,
    required this.eventsWsUrl,
    required this.flavor,
  });

  final String apiBaseUrl;
  final String eventsWsUrl;
  final String flavor;
}

final envConfigProvider = Provider<EnvConfig>((ref) {
  final api = dotenv.env['API_BASE_URL'] ?? 'http://localhost:5001';
  final ws = dotenv.env['EVENTS_WS_URL'] ?? 'ws://localhost:5002/events/media';
  final flavor = dotenv.env['FLAVOR'] ?? 'dev';
  return EnvConfig(apiBaseUrl: api, eventsWsUrl: ws, flavor: flavor);
});

Future<void> loadEnv() async {
  await dotenv.load(fileName: 'assets/env/.env');
}
