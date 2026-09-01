enum DownloadStatus { queued, downloading, completed, failed }

/// A handle to an in-flight download so it can be cancelled. Cancellation is
/// async so callers can await teardown (close the file handle) before deleting.
class DownloadTask {
  DownloadTask(this._cancel);
  final Future<void> Function() _cancel;
  Future<void> cancel() => _cancel();
}

/// A movie or series-episode saved (or being saved) for offline playback.
class DownloadItem {
  final String key; // 'vod:<id>' or 'ep:<id>'
  final String kind; // 'vod' | 'series'
  final String title;
  final String? image;

  /// Series context for an episode ('series' kind): the series name plus
  /// season/episode numbers — what external-subtitle search needs (it used
  /// to search for the bare episode title, "Pilot", as a MOVIE) and what the
  /// Downloads list shows so the row isn't just "Pilot". Null for movies and
  /// for entries persisted before these fields existed.
  final String? seriesName;
  final int? season;
  final int? episode;
  final String sourceId;
  final String remoteUrl;
  final String userAgent;
  final String ext;

  String localPath;
  int receivedBytes;
  int totalBytes;
  DownloadStatus status;
  bool savedToGallery;

  DownloadItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.sourceId,
    required this.remoteUrl,
    required this.userAgent,
    required this.ext,
    this.image,
    this.seriesName,
    this.season,
    this.episode,
    this.localPath = '',
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.status = DownloadStatus.queued,
    this.savedToGallery = false,
  });

  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  /// "S1E2 · Pilot" for an episode with known numbering, else the bare title.
  String get episodeLabel => (season != null && episode != null)
      ? 'S${season}E$episode · $title'
      : title;

  /// What the Downloads list shows: "Series · S1E2 · Pilot" for an episode.
  String get displayTitle =>
      seriesName != null ? '$seriesName · $episodeLabel' : title;

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'title': title,
        'image': image,
        'seriesName': seriesName,
        'season': season,
        'episode': episode,
        'sourceId': sourceId,
        'remoteUrl': remoteUrl,
        'userAgent': userAgent,
        'ext': ext,
        'localPath': localPath,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'status': status.name,
        'savedToGallery': savedToGallery,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        key: j['key'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        image: j['image'] as String?,
        seriesName: j['seriesName'] as String?,
        season: j['season'] as int?,
        episode: j['episode'] as int?,
        sourceId: j['sourceId'] as String,
        remoteUrl: j['remoteUrl'] as String,
        userAgent: j['userAgent'] as String,
        ext: j['ext'] as String? ?? 'mp4',
        localPath: j['localPath'] as String? ?? '',
        receivedBytes: j['receivedBytes'] as int? ?? 0,
        totalBytes: j['totalBytes'] as int? ?? 0,
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => DownloadStatus.queued,
        ),
        savedToGallery: j['savedToGallery'] as bool? ?? false,
      );
}
