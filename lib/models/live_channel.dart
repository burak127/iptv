import 'media_item.dart';

/// A live TV channel. For Xtream sources [id] is the numeric stream_id and the
/// URL is built on demand; for M3U sources [directUrl] holds the stream URL.
class LiveChannel implements MediaItem {
  @override
  final String id;
  @override
  final String name;
  @override
  final String categoryId;

  final String? logo;

  /// Channel number (Xtream `num` / M3U `tvg-chno`), used for number-zap + sort.
  final int? number;

  /// EPG channel id (Xtream `epg_channel_id` / M3U `tvg-id`) — kept for EPG.
  final String? epgChannelId;

  final bool tvArchive;
  final int tvArchiveDuration;

  /// Set for M3U channels (the URL is given directly). Null for Xtream.
  final String? directUrl;

  const LiveChannel({
    required this.id,
    required this.name,
    required this.categoryId,
    this.logo,
    this.number,
    this.epgChannelId,
    this.tvArchive = false,
    this.tvArchiveDuration = 0,
    this.directUrl,
  });

  @override
  MediaKind get kind => MediaKind.live;

  @override
  String? get imageUrl => logo;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'categoryId': categoryId,
        'logo': logo,
        'number': number,
        'epgChannelId': epgChannelId,
        'tvArchive': tvArchive,
        'tvArchiveDuration': tvArchiveDuration,
        'directUrl': directUrl,
      };

  factory LiveChannel.fromJson(Map<String, dynamic> j) => LiveChannel(
        id: j['id'] as String,
        name: j['name'] as String,
        categoryId: j['categoryId'] as String,
        logo: j['logo'] as String?,
        number: j['number'] as int?,
        epgChannelId: j['epgChannelId'] as String?,
        tvArchive: j['tvArchive'] as bool? ?? false,
        tvArchiveDuration: j['tvArchiveDuration'] as int? ?? 0,
        directUrl: j['directUrl'] as String?,
      );
}
