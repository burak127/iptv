import '../models/iptv_source.dart';
import '../models/live_channel.dart';
import '../models/movie.dart';
import '../models/series.dart';

/// Normalize a host to `http(s)://host[:port]` with no trailing slash.
String normalizeHost(String host) {
  var v = host.trim();
  if (!v.startsWith('http://') && !v.startsWith('https://')) {
    v = 'http://$v';
  }
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

/// The single source of truth for building playable stream URLs. Xtream URL
/// shapes: live={host}/live/{u}/{p}/{id}.{ext}, movie={host}/movie/..., series
/// episode={host}/series/..., timeshift={host}/timeshift/{u}/{p}/{dur}/{start}/{id}.ts
class StreamUrlBuilder {
  // Credentials go into path segments, so percent-encode reserved chars
  // (space, #, /, @, %, …) — the query path already does this via Uri.
  static String _cred(String? v) => Uri.encodeComponent(v ?? '');

  static String live(IptvSource s, LiveChannel ch) {
    if (ch.directUrl != null && ch.directUrl!.isNotEmpty) return ch.directUrl!;
    final ext = s.streamFormat == StreamFormat.hls ? 'm3u8' : 'ts';
    return '${normalizeHost(s.host!)}/live/${_cred(s.username)}/${_cred(s.password)}/${ch.id}.$ext';
  }

  static String movie(IptvSource s, Movie m) {
    final ext = (m.containerExtension != null && m.containerExtension!.isNotEmpty)
        ? m.containerExtension!
        : 'mp4';
    return '${normalizeHost(s.host!)}/movie/${_cred(s.username)}/${_cred(s.password)}/${m.id}.$ext';
  }

  static String episode(IptvSource s, Episode e) {
    final ext = (e.containerExtension != null && e.containerExtension!.isNotEmpty)
        ? e.containerExtension!
        : 'mp4';
    return '${normalizeHost(s.host!)}/series/${_cred(s.username)}/${_cred(s.password)}/${e.id}.$ext';
  }

  /// [startYmdHm] is 'YYYY-MM-DD:HH-MM' per the Xtream timeshift convention.
  static String timeshift(
    IptvSource s,
    LiveChannel ch,
    int durationMinutes,
    String startYmdHm,
  ) =>
      '${normalizeHost(s.host!)}/timeshift/${_cred(s.username)}/${_cred(s.password)}/$durationMinutes/$startYmdHm/${ch.id}.ts';
}
