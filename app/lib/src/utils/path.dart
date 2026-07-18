/// Returns the last non-empty path segment of [path], or [path] itself if it
/// has none (e.g. `/` or an empty string).
String lastPathSegment(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}
