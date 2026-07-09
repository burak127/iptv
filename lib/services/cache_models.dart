/// A cached payload plus when it was written, so callers can apply a TTL.
class CachedBlob {
  final dynamic data;
  final DateTime fetchedAt;
  const CachedBlob(this.data, this.fetchedAt);

  Duration get age => DateTime.now().difference(fetchedAt);
}
