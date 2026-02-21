import 'dart:async';

class SonosHttpRequest {
  const SonosHttpRequest({
    required this.url,
    required this.method,
    this.body,
    this.headers = const {},
    required this.timeout,
  });

  final Uri url;
  final String method;
  final String? body;
  final Map<String, String> headers;
  final Duration timeout;
}

class SonosHttpResponse {
  const SonosHttpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final String? reasonPhrase;
  final Map<String, String> headers;
  final String body;
}

abstract class SonosHttpTransport {
  Future<SonosHttpResponse> send(SonosHttpRequest request);
}
