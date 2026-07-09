/// The three kinds of browsable content an IPTV provider serves.
enum MediaKind { live, vod, series }

/// Common surface every browsable item exposes, so a single card/grid widget
/// can render live channels, movies and series interchangeably.
abstract class MediaItem {
  String get id;
  String get name;

  /// Logo (live) or poster (vod/series). May be null.
  String? get imageUrl;

  /// Category this item belongs to.
  String get categoryId;

  MediaKind get kind;
}
