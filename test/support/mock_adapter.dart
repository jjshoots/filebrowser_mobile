import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Minimal programmable [HttpClientAdapter] for unit tests: it records every
/// request and returns whatever the supplied [handler] decides, so we can both
/// assert on constructed URLs/headers and script multi-step flows (401 -> renew
/// -> retry) without a real server.
class MockAdapter implements HttpClientAdapter {
  MockAdapter(this.handler);

  /// Maps a request to a canned response.
  final ResponseBody Function(RequestOptions options) handler;

  /// Every request the client issued, in order.
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}

  /// Helper: a JSON response with the given [status].
  static ResponseBody json(Object? body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  /// Helper: a plain-text response (e.g. tokens, NDJSON, raw bodies).
  static ResponseBody text(String body,
          {int status = 200, Map<String, List<String>>? headers}) =>
      ResponseBody.fromString(body, status, headers: headers ?? const {});
}
