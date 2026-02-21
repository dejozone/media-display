import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_display/src/services/sonos_core/sonos_ssdp_discovery.dart';

class SonosSsdpDiscoveryIo implements SonosSsdpDiscoveryAdapter {
  const SonosSsdpDiscoveryIo();

  @override
  Future<List<String>> discoverHosts({
    required Duration timeout,
    required int maxHosts,
  }) async {
    const mcast = '239.255.255.250';
    const port = 1900;
    const searchTarget = 'urn:schemas-upnp-org:device:ZonePlayer:1';

    final message = [
      'M-SEARCH * HTTP/1.1',
      'HOST: $mcast:$port',
      'MAN: "ssdp:discover"',
      'MX: 1',
      'ST: $searchTarget',
      '',
      '',
    ].join('\r\n');

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;

    final discovered = <String>[];
    final seenHosts = <String>{};
    final completer = Completer<List<String>>();

    socket.send(utf8.encode(message), InternetAddress(mcast), port);
    Timer(const Duration(seconds: 1), () {
      socket.send(utf8.encode(message), InternetAddress(mcast), port);
    });

    StreamSubscription<RawSocketEvent>? sub;

    Future<void> finish() async {
      if (completer.isCompleted) {
        return;
      }
      socket.readEventsEnabled = false;
      await sub?.cancel();
      socket.close();
      completer.complete(discovered);
    }

    Timer(timeout, () {
      finish();
    });

    sub = socket.listen((event) async {
      if (event != RawSocketEvent.read) {
        return;
      }

      final dg = socket.receive();
      if (dg == null) {
        return;
      }

      final payload = utf8.decode(dg.data, allowMalformed: true);
      final location = _parseHeader(payload, 'LOCATION');
      if (location == null) {
        return;
      }

      final uri = Uri.tryParse(location);
      final host = uri?.host;
      if (host == null || host.isEmpty || seenHosts.contains(host)) {
        return;
      }

      seenHosts.add(host);
      discovered.add(host);

      if (maxHosts > 0 && discovered.length >= maxHosts) {
        await finish();
      }
    }, onError: (_) async {
      await finish();
    });

    return completer.future;
  }

  String? _parseHeader(String data, String header) {
    final lines = const LineSplitter().convert(data);
    final prefix = '$header:';
    for (final line in lines) {
      if (line.toUpperCase().startsWith(prefix.toUpperCase())) {
        return line.substring(prefix.length).trim();
      }
    }
    return null;
  }
}
