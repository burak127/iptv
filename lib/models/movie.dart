import 'media_item.dart';

/// A VOD movie (Xtream get_vod_streams / get_vod_info).
class Movie implements MediaItem {
  @override
  final String id; // stream_id
  @override
  final String name;
  @override
  final String categoryId;

  final String? poster;
  final String? containerExtension;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? year;
  final double? rating; // 0..10
  final int? durationSecs;

  const Movie({
    required this.id,
    required this.name,
    required this.categoryId,
    this.poster,
    this.containerExtension,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.year,
    this.rating,
    this.durationSecs,
  });

  @override
  MediaKind get kind => MediaKind.vod;

  @override
  String? get imageUrl => poster;

  Movie copyWith({
    String? plot,
    String? cast,
    String? director,
    String? genre,
    String? year,
    double? rating,
    int? durationSecs,
    String? containerExtension,
  }) =>
      Movie(
        id: id,
        name: name,
        categoryId: categoryId,
        poster: poster,
        containerExtension: containerExtension ?? this.containerExtension,
        plot: plot ?? this.plot,
        cast: cast ?? this.cast,
        director: director ?? this.director,
        genre: genre ?? this.genre,
        year: year ?? this.year,
        rating: rating ?? this.rating,
        durationSecs: durationSecs ?? this.durationSecs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'categoryId': categoryId,
        'poster': poster,
        'containerExtension': containerExtension,
        'plot': plot,
        'cast': cast,
        'director': director,
        'genre': genre,
        'year': year,
        'rating': rating,
        'durationSecs': durationSecs,
      };

  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
        id: j['id'] as String,
        name: j['name'] as String,
        categoryId: j['categoryId'] as String,
        poster: j['poster'] as String?,
        containerExtension: j['containerExtension'] as String?,
        plot: j['plot'] as String?,
        cast: j['cast'] as String?,
        director: j['director'] as String?,
        genre: j['genre'] as String?,
        year: j['year'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        durationSecs: j['durationSecs'] as int?,
      );
}
