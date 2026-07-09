import 'media_item.dart';

/// A series (Xtream get_series). Seasons/episodes come from get_series_info.
class Series implements MediaItem {
  @override
  final String id; // series_id
  @override
  final String name;
  @override
  final String categoryId;

  final String? poster; // cover
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? year;
  final double? rating;

  const Series({
    required this.id,
    required this.name,
    required this.categoryId,
    this.poster,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.year,
    this.rating,
  });

  @override
  MediaKind get kind => MediaKind.series;

  @override
  String? get imageUrl => poster;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'categoryId': categoryId,
        'poster': poster,
        'plot': plot,
        'cast': cast,
        'director': director,
        'genre': genre,
        'year': year,
        'rating': rating,
      };

  factory Series.fromJson(Map<String, dynamic> j) => Series(
        id: j['id'] as String,
        name: j['name'] as String,
        categoryId: j['categoryId'] as String,
        poster: j['poster'] as String?,
        plot: j['plot'] as String?,
        cast: j['cast'] as String?,
        director: j['director'] as String?,
        genre: j['genre'] as String?,
        year: j['year'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
      );
}

/// One season of a series, holding its episodes.
class Season {
  final int number;
  final List<Episode> episodes;

  const Season({required this.number, required this.episodes});

  Map<String, dynamic> toJson() => {
        'number': number,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };

  factory Season.fromJson(Map<String, dynamic> j) => Season(
        number: j['number'] as int,
        episodes: (j['episodes'] as List)
            .map((e) => Episode.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A single episode.
class Episode {
  final String id; // episode id used to build the stream URL
  final String title;
  final int seasonNumber;
  final int episodeNumber;
  final String? containerExtension;
  final String? plot;
  final String? poster;
  final int? durationSecs;

  const Episode({
    required this.id,
    required this.title,
    required this.seasonNumber,
    required this.episodeNumber,
    this.containerExtension,
    this.plot,
    this.poster,
    this.durationSecs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'containerExtension': containerExtension,
        'plot': plot,
        'poster': poster,
        'durationSecs': durationSecs,
      };

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id'] as String,
        title: j['title'] as String,
        seasonNumber: j['seasonNumber'] as int,
        episodeNumber: j['episodeNumber'] as int,
        containerExtension: j['containerExtension'] as String?,
        plot: j['plot'] as String?,
        poster: j['poster'] as String?,
        durationSecs: j['durationSecs'] as int?,
      );
}
