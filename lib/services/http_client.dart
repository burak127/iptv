import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

// Top-level so compute() can run it in a background isolate.
dynamic _decodeJsonBytes(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes, allowMalformed: true));

/// User-Agent that IPTV providers expect. The default Dart UA is frequently
/// blocked (403 / non-standard codes like 884).
const String kDefaultUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';

/// Thrown for a non-2xx HTTP response so callers/[IptvErrors] can map the code
/// (e.g. 884 → provider blocks M3U download).
class IptvHttpException implements Exception {
  final int statusCode;
  final String url;
  IptvHttpException(this.statusCode, this.url);

  @override
  String toString() => 'HTTP $statusCode ($url)';
}

/// One app-wide HTTP client: keep-alive pooling (respects single-connection
/// providers), a VLC User-Agent on every request, per-request timeouts, and
/// bounded exponential-backoff retry for transient failures (timeout / network
/// / 5xx) — never for 4xx or non-standard block codes (retrying wastes the one
/// allowed connection).
class IptvHttpClient {
  IptvHttpClient([http.Client? client]) : _client = client ?? http.Client();
  http.Client _client;

  // Requests in progress right now (across all live clients). Used to decide
  // whether a timed-out socket can be killed immediately without collateral.
  int _inFlight = 0;
  // Clients retired after a timeout, kept alive until nothing is in flight so a
  // healthy concurrent request never loses its bytes; then closed to reclaim the
  // abandoned (uncancellable) socket.
  final List<http.Client> _retired = [];

  /// package:http can't cancel an in-flight request — after a timeout the
  /// abandoned socket keeps downloading. Killing it means closing its client,
  /// which ALSO aborts every other request sharing that client. So only hard-
  /// close when this timed-out request is the sole one in flight; otherwise
  /// retire the client (new requests get a fresh connection) and defer the close
  /// until the last concurrent request has finished.
  void _handleTimeout(http.Client timedOut) {
    if (_inFlight <= 1) {
      try {
        timedOut.close();
      } catch (_) {}
      _retired.remove(timedOut);
      if (identical(timedOut, _client)) _client = http.Client();
    } else if (identical(timedOut, _client)) {
      _retired.add(_client);
      _client = http.Client();
    }
  }

  Future<http.Response> getRaw(
    Uri url, {
    String? userAgent,
    String? referrer,
    Duration timeout = const Duration(seconds: 15),
    int retries = 2,
  }) async {
    final headers = <String, String>{
      'User-Agent': userAgent ?? kDefaultUserAgent,
      if (referrer != null && referrer.isNotEmpty) 'Referer': referrer,
    };
    var attempt = 0;
    _inFlight++;
    try {
      while (true) {
        final client = _client; // re-read each attempt (may have been retired)
        try {
          final res = await client.get(url, headers: headers).timeout(timeout);
          final transient = res.statusCode >= 500 && res.statusCode < 600;
          if (transient && attempt < retries) {
            attempt++;
            await Future<void>.delayed(Duration(milliseconds: 500 << (attempt - 1)));
            continue;
          }
          return res;
        } on TimeoutException {
          _handleTimeout(client); // free the connection before retrying/giving up
          if (attempt >= retries) rethrow;
          attempt++;
          await Future<void>.delayed(Duration(milliseconds: 500 << (attempt - 1)));
        } on http.ClientException {
          if (attempt >= retries) rethrow;
          attempt++;
          await Future<void>.delayed(Duration(milliseconds: 500 << (attempt - 1)));
        }
      }
    } finally {
      _inFlight--;
      if (_inFlight == 0 && _retired.isNotEmpty) {
        for (final c in _retired) {
          try {
            c.close();
          } catch (_) {}
        }
        _retired.clear();
      }
    }
  }

  Future<dynamic> getJson(
    Uri url, {
    String? userAgent,
    String? referrer,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final res = await getRaw(url, userAgent: userAgent, referrer: referrer, timeout: timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw IptvHttpException(res.statusCode, url.toString());
    }
    // Xtream panels send JSON without a charset → res.body would fall back to
    // latin1 and garble æøå in every channel/movie/EPG name. Decode as UTF-8.
    // Multi-MB catalogs decode in a background isolate so a weak TV CPU's UI
    // thread never stalls for seconds; small payloads skip the isolate cost.
    if (res.bodyBytes.length > 256 * 1024) {
      return compute(_decodeJsonBytes, res.bodyBytes);
    }
    return jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  Future<String> getText(
    Uri url, {
    String? userAgent,
    String? referrer,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final res = await getRaw(url, userAgent: userAgent, referrer: referrer, timeout: timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw IptvHttpException(res.statusCode, url.toString());
    }
    // Playlists are de-facto UTF-8 but servers rarely declare a charset (which
    // makes res.body fall back to latin1 and garble æøå/ç/ü). Decode UTF-8
    // leniently — allowMalformed means this can never throw.
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  void close() {
    try {
      _client.close();
    } catch (_) {}
    for (final c in _retired) {
      try {
        c.close();
      } catch (_) {}
    }
    _retired.clear();
  }
}
