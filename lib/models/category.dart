/// Bucket for items whose panel returns a null/empty category_id — without it
/// they would be invisible everywhere except "All".
const String kUncategorizedId = '__uncat__';

/// A group/category of channels.
///
/// For M3U playlists the [id] is the `group-title` string itself (playlists
/// have no numeric ids). For Xtream Codes it is the numeric `category_id`.
class IptvCategory {
  final String id;
  final String name;

  const IptvCategory({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory IptvCategory.fromJson(Map<String, dynamic> j) =>
      IptvCategory(id: j['id'] as String, name: j['name'] as String);

  @override
  bool operator ==(Object other) =>
      other is IptvCategory && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}
