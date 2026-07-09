import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/download_item.dart';

/// Native (dart:io) file downloader with progress, resume + cancellation.
class DownloadIo {
  static bool get supported => true;

  static bool fileExists(String path) =>
      path.isNotEmpty && File(path).existsSync();

  /// Size of a partial download already on disk (0 if none). Lets the manager
  /// resume with a Range request instead of restarting a multi-GB transfer
  /// from byte 0 after the app was killed / backgrounded.
  static int partialBytes(String path) {
    if (path.isEmpty) return 0;
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Copies a finished download into the device gallery ([album]) so it shows
  /// up in Photos/Videos/Files. Requests media access on first use. Returns
  /// false if denied or the format is rejected by the gallery.
  static Future<bool> saveToGallery(String path, String album) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) return false;
      }
      await Gal.putVideo(path, album: album);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> downloadsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  static Future<void> deleteFile(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* best-effort */}
  }

  static DownloadTask start({
    required String url,
    required String path,
    required String userAgent,
    int resumeFrom = 0,
    required void Function(int received, int total) onProgress,
    required void Function() onDone,
    required void Function(Object error) onError,
  }) {
    final client = http.Client();
    var cancelled = false;
    var finished = false; // guards against double onDone / onError
    StreamSubscription<List<int>>? sub;
    IOSink? sink;

    // Closing an IOSink is where deferred write errors (e.g. ENOSPC / disk full)
    // finally surface. It must NEVER throw out of a callback — a throw here
    // would abandon cleanup and freeze the whole download queue.
    Future<void> closeSink() async {
      final s = sink;
      sink = null;
      if (s == null) return;
      try {
        await s.flush();
      } catch (_) {/* surfaced via done/close */}
      try {
        await s.close();
      } catch (_) {/* disk full / already closed — best-effort */}
    }

    Future<void> cleanup({bool deleteFileToo = false}) async {
      try {
        await sub?.cancel();
      } catch (_) {}
      await closeSink();
      client.close();
      if (deleteFileToo) await deleteFile(path);
    }

    Future<void> fail(Object e) async {
      if (finished) return;
      finished = true;
      await cleanup(deleteFileToo: true);
      onError(e);
    }

    () async {
      try {
        final resuming = resumeFrom > 0 && File(path).existsSync();
        final req = http.Request('GET', Uri.parse(url))
          ..headers['User-Agent'] = userAgent;
        if (resuming) req.headers['Range'] = 'bytes=$resumeFrom-';
        final resp = await client.send(req);
        if (cancelled) {
          await cleanup(); // keep the partial file for a later resume
          return;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          await fail('HTTP ${resp.statusCode}');
          return;
        }

        // 206 = server honored our Range -> append to the partial file.
        // Anything else (200) means it sent the whole body -> start clean so
        // we never concatenate two copies into one corrupt file.
        final appended = resp.statusCode == 206 && resuming;
        var received = appended ? resumeFrom : 0;
        final body = resp.contentLength ?? 0;
        final total = appended && body > 0 ? resumeFrom + body : body;

        sink = File(path).openWrite(
          mode: appended ? FileMode.writeOnlyAppend : FileMode.writeOnly,
        );
        // Surface deferred write errors (disk full) the moment the OS reports
        // them, instead of only at close() inside an unawaited callback.
        unawaited(sink!.done.catchError((Object e) => fail(e)));

        onProgress(received, total);
        sub = resp.stream.listen(
          (chunk) {
            if (finished) return;
            received += chunk.length;
            sink!.add(chunk);
            onProgress(received, total);
          },
          onDone: () async {
            if (finished || cancelled) return;
            try {
              await sink?.flush();
              await sink?.close();
              sink = null;
            } catch (e) {
              await fail(e); // ENOSPC surfaces here on the final flush/close
              return;
            }
            if (finished) return; // sink.done may have already failed us
            finished = true;
            try {
              await sub?.cancel();
            } catch (_) {}
            client.close();
            onDone();
          },
          onError: (Object e) => fail(e),
          cancelOnError: true,
        );
      } catch (e) {
        await fail(e);
      }
    }();

    return DownloadTask(() async {
      cancelled = true;
      finished = true;
      // Keep the partial file — the manager decides whether to delete (remove)
      // or resume it (interrupted). cleanup() here can never throw.
      await cleanup();
    });
  }
}
