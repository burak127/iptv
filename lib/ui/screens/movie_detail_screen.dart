import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/download_item.dart';
import '../../models/media_item.dart';
import '../../models/movie.dart';
import '../../services/download_manager.dart';
import '../../services/http_client.dart';
import '../../services/progress_repository.dart';
import '../../services/stream_url_builder.dart';
import '../../state/app_state.dart';
import '../widgets/media_card.dart';
import 'player_screen.dart';

const double _wideBreakpoint = 720;

/// Full-screen detail page for a single VOD [Movie]. Enriches the passed movie
/// with plot/genre/duration via `movieInfo`, shows a large poster, metadata and
/// a D-pad-friendly action row (Afspil / Fortsæt / Start forfra / favorit).
class MovieDetailScreen extends StatefulWidget {
  const MovieDetailScreen({super.key, required this.movie, this.siblingMovies});

  final Movie movie;

  /// The list this movie was opened from (a category/browse list) — passed
  /// through to the player so "switch movie like a channel" (prev/next
  /// buttons + swipe) has something to page through. Null when opened from
  /// a context with no stable list (e.g. search results).
  final List<Movie>? siblingMovies;

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Movie _movie = widget.movie;
  bool _loading = true;
  ResumePoint? _resume;

  String get _resumeKey => 'vod:${widget.movie.id}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // Enriched details (best effort — fall back to what we already have).
    final source = state.active;
    if (source != null) {
      try {
        final enriched = await state.repository.movieInfo(source, widget.movie);
        if (mounted) setState(() => _movie = enriched);
      } catch (_) {
        // Keep the passed-in movie on error.
      }
    }
    final resume = await state.resumeFor(_resumeKey);
    if (!mounted) return;
    setState(() {
      _resume = resume;
      _loading = false;
    });
  }

  void _play({bool fromStart = false}) {
    final state = context.read<AppState>();
    final source = state.active;
    if (source == null) return;
    state.markWatched(_movie);
    // Play the downloaded copy when present on disk, otherwise stream.
    final local = context
        .read<DownloadManager>()
        .playableLocalPath(_resumeKey, sourceId: source.id);
    final url = local ?? StreamUrlBuilder.movie(source, _movie);
    final startAt = (!fromStart && _resume != null)
        ? Duration(seconds: _resume!.positionSecs)
        : null;
    final siblings = widget.siblingMovies;
    final siblingIndex =
        siblings?.indexWhere((m) => m.id == _movie.id) ?? -1;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen.onDemand(
          source: source,
          url: url,
          title: _movie.name,
          resumeKey: _resumeKey,
          startAt: startAt,
          durationHint: _movie.durationSecs ?? 0,
          searchTitle: _movie.name,
          movies: (siblings != null && siblings.length > 1) ? siblings : null,
          movieIndex: siblingIndex >= 0 ? siblingIndex : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isFav = state.isFavorite(MediaKind.vod, _movie.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(_movie.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= _wideBreakpoint;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _poster(width: 240),
                      const SizedBox(width: 24),
                      Expanded(child: _details(isFav)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: _poster(width: 200)),
                      const SizedBox(height: 20),
                      _details(isFav),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _poster({required double width}) {
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 0.62,
        child: NetworkImageBox(
          url: _movie.poster,
          placeholderIcon: Icons.movie,
          fit: BoxFit.cover,
          borderRadius: 12,
        ),
      ),
    );
  }

  Widget _details(bool isFav) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _movie.name,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _metaLine(),
        const SizedBox(height: 20),
        _actions(isFav),
        if (_loading) ...[
          const SizedBox(height: 16),
          const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Henter detaljer …',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ],
        if ((_movie.plot ?? '').isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            _movie.plot!,
            style: const TextStyle(fontSize: 14, height: 1.45, color: Colors.white70),
          ),
        ],
        if ((_movie.cast ?? '').isNotEmpty) ...[
          const SizedBox(height: 16),
          _infoRow('Medvirkende', _movie.cast!),
        ],
        if ((_movie.director ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          _infoRow('Instruktør', _movie.director!),
        ],
      ],
    );
  }

  /// year · rating · genre · duration — only the parts we actually have.
  Widget _metaLine() {
    final parts = <String>[
      if ((_movie.year ?? '').isNotEmpty) _movie.year!,
      if (_movie.rating != null) '★ ${_movie.rating!.toStringAsFixed(1)}',
      if ((_movie.genre ?? '').isNotEmpty) _movie.genre!,
      if (_movie.durationSecs != null && _movie.durationSecs! > 0)
        _formatDuration(_movie.durationSecs!),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join('  ·  '),
      style: const TextStyle(fontSize: 14, color: Colors.white60),
    );
  }

  Widget _actions(bool isFav) {
    final resume = _resume;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          autofocus: true,
          onPressed: () => _play(fromStart: resume == null),
          icon: const Icon(Icons.play_arrow),
          label: Text(
            resume != null
                ? 'Fortsæt (${_formatClock(resume.positionSecs)})'
                : 'Afspil',
          ),
        ),
        if (resume != null)
          OutlinedButton.icon(
            onPressed: () => _play(fromStart: true),
            icon: const Icon(Icons.replay),
            label: const Text('Start forfra'),
          ),
        _downloadButton(),
        IconButton(
          tooltip: isFav ? 'Fjern favorit' : 'Tilføj favorit',
          onPressed: () =>
              context.read<AppState>().toggleFavorite(MediaKind.vod, _movie.id),
          icon: Icon(
            isFav ? Icons.star : Icons.star_border,
            color: isFav ? Colors.amber : Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _downloadButton() {
    final dm = context.watch<DownloadManager>();
    if (!dm.supported) return const SizedBox.shrink();
    final sid = context.read<AppState>().active?.id;
    final item = dm.byKey(_resumeKey, sourceId: sid);
    if (item == null) {
      return OutlinedButton.icon(
        onPressed: _startDownload,
        icon: const Icon(Icons.download),
        label: const Text('Download'),
      );
    }
    switch (item.status) {
      case DownloadStatus.completed:
        return OutlinedButton.icon(
          onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
          icon: const Icon(Icons.download_done, color: Colors.greenAccent),
          label: const Text('Hentet'),
        );
      case DownloadStatus.downloading:
        return OutlinedButton.icon(
          onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
          icon: const Icon(Icons.close),
          label: Text('${(item.progress * 100).toStringAsFixed(0)}%'),
        );
      case DownloadStatus.queued:
        return OutlinedButton.icon(
          onPressed: () => dm.remove(item.key, sourceId: item.sourceId),
          icon: const Icon(Icons.hourglass_empty),
          label: const Text('I kø'),
        );
      case DownloadStatus.failed:
        return OutlinedButton.icon(
          onPressed: () => dm.retry(item.key, sourceId: item.sourceId),
          icon: const Icon(Icons.refresh),
          label: const Text('Prøv igen'),
        );
    }
  }

  void _startDownload() {
    final source = context.read<AppState>().active;
    if (source == null) return;
    context.read<DownloadManager>().enqueue(DownloadItem(
          key: _resumeKey,
          kind: 'vod',
          title: _movie.name,
          image: _movie.poster,
          sourceId: source.id,
          remoteUrl: StreamUrlBuilder.movie(source, _movie),
          userAgent: source.userAgent ?? kDefaultUserAgent,
          ext: (_movie.containerExtension?.isNotEmpty ?? false)
              ? _movie.containerExtension!
              : 'mp4',
        ));
  }

  Widget _infoRow(String label, String value) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 13, color: Colors.white70),
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          TextSpan(text: value),
        ],
      ),
    );
  }

  /// Format a total-seconds duration as `h t min` (Danish), e.g. `1 t 42 min`.
  String _formatDuration(int totalSecs) {
    final totalMin = totalSecs ~/ 60;
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h > 0) return '$h t $m min';
    return '$m min';
  }

  /// Format a resume position as mm:ss (or h:mm:ss past an hour).
  String _formatClock(int totalSecs) {
    final h = totalSecs ~/ 3600;
    final m = (totalSecs % 3600) ~/ 60;
    final s = totalSecs % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }
}
