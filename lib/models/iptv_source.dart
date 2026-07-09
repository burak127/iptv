import 'dart:convert';

/// The two ways a user can connect to their IPTV provider.
enum SourceType { m3u, xtream }

/// Preferred container/format when building stream URLs.
enum StreamFormat { auto, ts, hls }

/// A saved IPTV provider configuration.
///
/// - [SourceType.m3u]    → uses [m3uUrl].
/// - [SourceType.xtream] → uses [host] + [username] + [password].
class IptvSource {
  final String id;
  final String name;
  final SourceType type;

  // M3U
  final String? m3uUrl;

  // Xtream Codes
  final String? host; // e.g. http://example.com:8080  (no trailing slash needed)
  final String? username;
  final String? password;

  // Advanced / optional
  final String? userAgent; // null → app default (VLC UA)
  final String? referrer;
  final String? epgUrl; // external XMLTV for M3U sources
  final StreamFormat streamFormat;

  const IptvSource({
    required this.id,
    required this.name,
    required this.type,
    this.m3uUrl,
    this.host,
    this.username,
    this.password,
    this.userAgent,
    this.referrer,
    this.epgUrl,
    this.streamFormat = StreamFormat.auto,
  });

  factory IptvSource.m3u({
    required String id,
    required String name,
    required String url,
    String? userAgent,
    String? epgUrl,
  }) =>
      IptvSource(
        id: id,
        name: name,
        type: SourceType.m3u,
        m3uUrl: url,
        userAgent: userAgent,
        epgUrl: epgUrl,
      );

  /// Recognizes an Xtream-style M3U URL (`…/get.php?username=U&password=P`)
  /// and converts it to an Xtream source. Many providers deliberately block
  /// the get.php playlist download (e.g. HTTP 884) while their Xtream API
  /// works fine — the same credentials ride inside the link, so we can serve
  /// the user via the API instead. Returns null when the URL carries no
  /// embedded credentials (a plain playlist link).
  static IptvSource? xtreamFromM3uUrl({
    required String id,
    required String name,
    required String url,
  }) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isAbsolute) return null;
    final user = uri.queryParameters['username'];
    final pass = uri.queryParameters['password'];
    if (user == null || user.isEmpty || pass == null || pass.isEmpty) {
      return null;
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    return IptvSource.xtream(
      id: id,
      name: name,
      host: '${uri.scheme}://${uri.host}$port',
      username: user,
      password: pass,
    );
  }

  factory IptvSource.xtream({
    required String id,
    required String name,
    required String host,
    required String username,
    required String password,
    String? userAgent,
  }) =>
      IptvSource(
        id: id,
        name: name,
        type: SourceType.xtream,
        host: host,
        username: username,
        password: password,
        userAgent: userAgent,
      );

  bool get isXtream => type == SourceType.xtream;

  IptvSource copyWith({
    String? name,
    String? userAgent,
    String? referrer,
    String? epgUrl,
    StreamFormat? streamFormat,
  }) =>
      IptvSource(
        id: id,
        name: name ?? this.name,
        type: type,
        m3uUrl: m3uUrl,
        host: host,
        username: username,
        password: password,
        userAgent: userAgent ?? this.userAgent,
        referrer: referrer ?? this.referrer,
        epgUrl: epgUrl ?? this.epgUrl,
        streamFormat: streamFormat ?? this.streamFormat,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'm3uUrl': m3uUrl,
        'host': host,
        'username': username,
        'password': password,
        'userAgent': userAgent,
        'referrer': referrer,
        'epgUrl': epgUrl,
        'streamFormat': streamFormat.name,
      };

  factory IptvSource.fromJson(Map<String, dynamic> json) => IptvSource(
        id: json['id'] as String,
        name: json['name'] as String,
        type: SourceType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => SourceType.m3u,
        ),
        m3uUrl: json['m3uUrl'] as String?,
        host: json['host'] as String?,
        username: json['username'] as String?,
        password: json['password'] as String?,
        userAgent: json['userAgent'] as String?,
        referrer: json['referrer'] as String?,
        epgUrl: json['epgUrl'] as String?,
        streamFormat: StreamFormat.values.firstWhere(
          (f) => f.name == json['streamFormat'],
          orElse: () => StreamFormat.auto,
        ),
      );

  static String encodeList(List<IptvSource> sources) =>
      jsonEncode(sources.map((s) => s.toJson()).toList());

  static List<IptvSource> decodeList(String raw) {
    final decoded = jsonDecode(raw);
    // Tolerate both the bare-list (v1) and the {schemaVersion, sources} shapes.
    final list = decoded is Map ? decoded['sources'] as List : decoded as List;
    return list
        .map((e) => IptvSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
