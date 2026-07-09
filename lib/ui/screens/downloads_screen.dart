import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/download_item.dart';
import '../../models/iptv_source.dart';
import '../../services/download_manager.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/media_card.dart';
import 'player_screen.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: _body(context, dm),
    );
  }

  Widget _body(BuildContext context, DownloadManager dm) {
    if (!dm.supported) {
      return const EmptyState(
        icon: Icons.cloud_off,
        title: 'Downloads er ikke tilgængelige her',
        message: 'Offline-download virker på Android/telefon, ikke i browseren.',
      );
    }
    final items = dm.items;
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.download_done,
        title: 'Ingen downloads endnu',
        message: 'Åbn en film eller et afsnit og tryk på Download.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _DownloadTile(item: items[i]),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.item});
  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    final dm = context.read<DownloadManager>();
    return FocusRing(
      borderRadius: 12,
      child: Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            SizedBox(
              width: 54,
              height: 72,
              child: NetworkImageBox(
                url: item.image,
                placeholderIcon:
                    item.kind == 'series' ? Icons.video_library : Icons.movie,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  _status(context, item),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _actions(context, dm),
          ],
        ),
      ),
      ),
    );
  }

  Widget _status(BuildContext context, DownloadItem item) {
    switch (item.status) {
      case DownloadStatus.completed:
        return Text(
          item.savedToGallery
              ? 'Hentet · ${_fmtSize(item.totalBytes)} · i galleriet'
              : 'Hentet · ${_fmtSize(item.totalBytes)}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        );
      case DownloadStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: item.totalBytes > 0 ? item.progress : null,
            ),
            const SizedBox(height: 4),
            Text(
              item.totalBytes > 0
                  ? '${(item.progress * 100).toStringAsFixed(0)}% · ${_fmtSize(item.receivedBytes)} / ${_fmtSize(item.totalBytes)}'
                  : 'Henter… ${_fmtSize(item.receivedBytes)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        );
      case DownloadStatus.queued:
        return const Text('I kø',
            style: TextStyle(color: Colors.white54, fontSize: 12));
      case DownloadStatus.failed:
        return const Text('Fejlede',
            style: TextStyle(color: Colors.redAccent, fontSize: 12));
    }
  }

  Widget _actions(BuildContext context, DownloadManager dm) {
    switch (item.status) {
      case DownloadStatus.completed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_circle_fill),
              iconSize: 34,
              onPressed: () => _play(context),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
            ),
          ],
        );
      case DownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => dm.retry(item.key, sourceId: item.sourceId),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
            ),
          ],
        );
      case DownloadStatus.downloading:
      case DownloadStatus.queued:
        return IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
        );
    }
  }

  // Async so it can look up a saved resume point first — a synchronous
  // handler here previously never passed `startAt`, so tapping play on an
  // already-partially-watched download silently always restarted at 0:00,
  // even though its progress was (and still is) saved every ~5s during
  // playback via PlaybackController.
  Future<void> _play(BuildContext context) async {
    final app = context.read<AppState>();
    // A local file needs no live source — resolve one, else synthesize (so
    // offline playback works even with zero configured sources).
    IptvSource resolveSource() {
      if (app.active != null) return app.active!;
      for (final s in app.sources) {
        if (s.id == item.sourceId) return s;
      }
      if (app.sources.isNotEmpty) return app.sources.first;
      return IptvSource.m3u(
        id: item.sourceId,
        name: 'Offline',
        url: item.localPath,
        userAgent: item.userAgent,
      );
    }

    final resume = await app.resumeFor(item.key);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.onDemand(
        source: resolveSource(),
        url: item.localPath,
        title: item.title,
        resumeKey: item.key,
        startAt: resume != null ? Duration(seconds: resume.positionSecs) : null,
        searchTitle: item.title,
      ),
    ));
  }

  static String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 MB';
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) {
      return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }
}
