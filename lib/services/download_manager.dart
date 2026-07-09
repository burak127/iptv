import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_item.dart';
import 'download_platform.dart';

/// Manages offline downloads of movies / episodes: a persisted queue processed
/// one at a time, with progress and cancellation. Provided app-wide so any
/// screen can start a download and the Downloads tab can list them.
class DownloadManager extends ChangeNotifier {
  DownloadManager() {
    _load();
  }

  final List<DownloadItem> _items = [];
  DownloadTask? _active;
  int _activePct = -1;
  bool _starting = false; // synchronous reservation across the _process await gap
  final Completer<void> _ready = Completer<void>(); // gates enqueue until loaded

  /// When true, a finished download is also copied into the device gallery.
  bool saveToGallery = true;

  Future<void> setSaveToGallery(bool value) async {
    saveToGallery = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('save_to_gallery', value);
    notifyListeners();
  }

  List<DownloadItem> get items => List.unmodifiable(_items);
  bool get supported => DownloadIo.supported;

  /// Xtream stream/episode ids are provider-local and collide across
  /// providers — lookups must be scoped to the source when one is known.
  DownloadItem? byKey(String key, {String? sourceId}) {
    for (final i in _items) {
      if (i.key == key && (sourceId == null || i.sourceId == sourceId)) {
        return i;
      }
    }
    return null;
  }

  bool isCompleted(String key, {String? sourceId}) =>
      byKey(key, sourceId: sourceId)?.status == DownloadStatus.completed;

  /// The on-disk path only if the download is complete AND the file still
  /// exists; otherwise null (and it repairs the stale 'completed' state).
  String? playableLocalPath(String key, {String? sourceId}) {
    final item = byKey(key, sourceId: sourceId);
    if (item == null ||
        item.status != DownloadStatus.completed ||
        item.localPath.isEmpty) {
      return null;
    }
    if (!DownloadIo.fileExists(item.localPath)) {
      item.status = DownloadStatus.failed;
      unawaited(_persist());
      notifyListeners();
      return null;
    }
    return item.localPath;
  }

  Future<void> enqueue(DownloadItem item) async {
    if (!supported) return;
    await _ready.future; // don't race the initial _load()'s _items.clear()
    if (byKey(item.key, sourceId: item.sourceId) != null) return;
    _items.add(item);
    await _persist();
    notifyListeners();
    _process();
  }

  Future<void> remove(String key, {String? sourceId}) async {
    final item = byKey(key, sourceId: sourceId);
    if (item == null) return;
    if (item.status == DownloadStatus.downloading && _active != null) {
      await _active!.cancel(); // close the file handle before deleting
      _active = null;
    }
    _items.remove(item);
    await DownloadIo.deleteFile(item.localPath);
    await _persist();
    notifyListeners();
    _process();
  }

  Future<void> retry(String key, {String? sourceId}) async {
    final item = byKey(key, sourceId: sourceId);
    if (item == null) return;
    if (item.status == DownloadStatus.downloading && _active != null) {
      await _active!.cancel();
      _active = null;
    }
    // Explicit retry = clean restart: drop any partial bytes so we don't try to
    // resume a file the user is deliberately re-fetching (e.g. after a failure).
    await DownloadIo.deleteFile(item.localPath);
    item.status = DownloadStatus.queued;
    item.receivedBytes = 0;
    await _persist();
    notifyListeners();
    _process();
  }

  Future<void> _process() async {
    if (_active != null || _starting) return; // one download at a time
    DownloadItem? next;
    for (final i in _items) {
      if (i.status == DownloadStatus.queued) {
        next = i;
        break;
      }
    }
    if (next == null) return;

    _starting = true; // reserve BEFORE any await, cleared once _active is set
    var aborted = false;
    try {
      final item = next;
      item.status = DownloadStatus.downloading;
      _activePct = -1;
      notifyListeners();

      final dir = await DownloadIo.downloadsDir();
      // The item may have been removed while we awaited — starting it anyway
      // would create an untracked ghost download nothing can cancel.
      if (!_items.contains(item)) {
        aborted = true;
        return;
      }
      // Filename includes the source so same-id items from two providers
      // can't overwrite each other's files.
      item.localPath = '$dir/${_safeName('${item.sourceId}_${item.key}')}.${item.ext}';

      // Resume from whatever bytes survived a previous kill/interruption; the
      // on-disk file size is the source of truth (0 for a fresh download).
      final resumeFrom = DownloadIo.partialBytes(item.localPath);
      if (resumeFrom > 0) item.receivedBytes = resumeFrom;

      _active = DownloadIo.start(
        url: item.remoteUrl,
        path: item.localPath,
        userAgent: item.userAgent,
        resumeFrom: resumeFrom,
        onProgress: (received, total) {
          item.receivedBytes = received;
          item.totalBytes = total;
          final pct = total > 0 ? (received * 100 ~/ total) : -1;
          if (pct != _activePct) {
            _activePct = pct;
            notifyListeners();
          }
        },
        onDone: () async {
          item.status = DownloadStatus.completed;
          _active = null;
          if (saveToGallery) {
            item.savedToGallery =
                await DownloadIo.saveToGallery(item.localPath, 'IPTV Player');
          }
          await _persist();
          notifyListeners();
          _process();
        },
        onError: (_) async {
          item.status = DownloadStatus.failed;
          _active = null;
          await _persist();
          notifyListeners();
          _process();
        },
      );
    } finally {
      _starting = false;
      if (aborted) _process(); // pick up the next queued item
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'downloads',
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      saveToGallery = prefs.getBool('save_to_gallery') ?? true;
      final raw = prefs.getString('downloads');
      if (raw != null) {
        _items.clear();
        for (final e in jsonDecode(raw) as List) {
          final item = DownloadItem.fromJson((e as Map).cast<String, dynamic>());
          // A download interrupted by an app kill is re-queued; the partial
          // file (if any) is kept so _process() can resume it via a Range
          // request instead of re-downloading from byte 0.
          if (item.status == DownloadStatus.downloading) {
            item.status = DownloadStatus.queued;
          }
          _items.add(item);
        }
        notifyListeners();
      }
    } catch (_) {
      /* ignore corrupt store */
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
    _process();
  }

  String _safeName(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
}
