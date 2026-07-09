import '../models/download_item.dart';

/// Web fallback — offline downloads need a real filesystem (unavailable on web).
class DownloadIo {
  static bool get supported => false;

  static bool fileExists(String path) => false;

  static int partialBytes(String path) => 0;

  static Future<bool> saveToGallery(String path, String album) async => false;

  static Future<String> downloadsDir() async => '';

  static Future<void> deleteFile(String path) async {}

  static DownloadTask start({
    required String url,
    required String path,
    required String userAgent,
    int resumeFrom = 0,
    required void Function(int received, int total) onProgress,
    required void Function() onDone,
    required void Function(Object error) onError,
  }) {
    onError('Downloads understøttes ikke i browseren');
    return DownloadTask(() async {});
  }
}
