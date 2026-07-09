// Defensive coercion helpers — Xtream panels return the same field as either
// a string or a number depending on the provider, so never cast directly.

String? asStringOrNull(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

String asString(dynamic v, [String fallback = '']) => asStringOrNull(v) ?? fallback;

int? asIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
}

double? asDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  final s = v.toString().trim().replaceAll(',', '.');
  return double.tryParse(s);
}

bool asBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v?.toString().toLowerCase().trim();
  return s == '1' || s == 'true' || s == 'yes';
}

/// Xtream sometimes returns lists, sometimes an object keyed by index, sometimes
/// an error string. Always hand back a List (possibly empty).
List<dynamic> asList(dynamic v) {
  if (v is List) return v;
  if (v is Map) return v.values.toList();
  return const [];
}
