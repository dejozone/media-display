import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_display/src/services/sonos_core/sonos_http_transport.dart';

class SonosHttpTransportIo implements SonosHttpTransport {
  const SonosHttpTransportIo();

  @override
  Future<SonosHttpResponse> send(SonosHttpRequest request) async {
    final client = HttpClient()..connectionTimeout = request.timeout;
    final verb = request.method.toUpperCase();

    try {
      final req =
          await client.openUrl(verb, request.url).timeout(request.timeout);
      request.headers.forEach((key, value) {
        req.headers.set(key, value);
      });

      final body = request.body;
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers
          ..chunkedTransferEncoding = false
          ..contentLength = bytes.length;
        req.add(bytes);
      }

      final resp = await req.close().timeout(request.timeout);
      final respBody = await resp.transform(utf8.decoder).join();

      final flatHeaders = <String, String>{};
      resp.headers.forEach((header, values) {
        if (values.isNotEmpty) {
          flatHeaders[header.toLowerCase()] = values.first;
        }
      });

      return SonosHttpResponse(
        statusCode: resp.statusCode,
        reasonPhrase: resp.reasonPhrase,
        headers: flatHeaders,
        body: respBody,
      );
    } finally {
      client.close(force: true);
    }
  }
}
