import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/download_item.dart';
import '../../models/series.dart';
import '../../services/download_manager.dart';
import '../../services/http_client.dart';
import '../../services/progress_repository.dart';
import '../../services/stream_url_builder.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/focusable_card.dart';
import '../widgets/media_card.dart';
import 'player_screen.dart';

const double _wideBreakpoint = 820;

/// Detail view for a [Series]: fetches its seasons/episodes on open, lets the
/// user pick a season and play an episode (resuming where they left off).
class SeriesDetailScreen extends StatefulWidget {
  const SeriesDetailScreen({super.key, required this.series});

  final Series series;

  @override
  State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  List<Season> _seasons = const [];
  int? _selectedSeason;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSeasons();
  }

  Future<void> _loadSeasons() async {
    final state = context.read<AppState>();
    final source = state.active;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = 'Ingen aktiv kilde';
      });
      return;
    }
    try {
      final seasons = await state.repository.seriesInfo(source, widget.series.id);
      seasons.sort((a, b) => a.number.compareTo(b.number));
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _selectedSeason = seasons.isNotEmpty ? seasons.first.number : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Season? get _currentSeason {
    for (final s in _seasons) {
      if (s.number == _selectedSeason) return s;
    }
    return _seasons.isNotEmpty ? _seasons.first : null;
  }

  Future<void> _play(Episode ep) async {
    final state = context.read<AppState>();
    final source = state.active;
    if (source == null) return;
    final key = 'ep:${ep.id}';
    // Prefer a downloaded copy on disk for offline playback.
    final local = context
        .read<DownloadManager>()
        .playableLocalPath(key, sourceId: source.id);
    final url = local ?? StreamUrlBuilder.episode(source, ep);
    await state.markWatched(widget.series);
    final resume = await state.resumeFor(key);
    if (!mounted) return;
    // Flat, ordered episode list so the player can auto-advance (binge mode).
    final allEpisodes = [for (final s in _seasons) ...s.episodes];
    final epIndex = allEpisodes.indexWhere((e) => e.id == ep.id);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.onDemand(
        source: source,
        url: url,
        title: 'S${ep.seasonNumber}E${ep.episodeNumber} · ${ep.title}',
        resumeKey: key,
        startAt: resume == null
            ? null
            : Duration(seconds: resume.positionSecs),
        durationHint: ep.durationSecs ?? 0,
        searchTitle: widget.series.name,
        season: ep.seasonNumber,
        episode: ep.episodeNumber,
        episodes: allEpisodes,
        episodeIndex: epIndex >= 0 ? epIndex : null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.series.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _seasons.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        title: 'Kunne ikke hente afsnit',
        message: _error,
        actionLabel: 'Prøv igen',
        onAction: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _loadSeasons();
        },
      );
    }
    if (_seasons.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        title: 'Ingen afsnit',
        message: 'Denne serie har ingen tilgængelige afsnit.',
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _wideBreakpoint;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _Header(series: widget.series, wide: wide)),
            SliverToBoxAdapter(child: _seasonSelector()),
            const SliverToBoxAdapter(child: Divider(height: 1)),
            _episodeList(),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  Widget _seasonSelector() {
    if (_seasons.length <= 1) {
      final only = _seasons.isNotEmpty ? _seasons.first.number : 1;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Sæson $only',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = _seasons[i];
          return FocusRing(
            borderRadius: 20,
            child: ChoiceChip(
              label: Text('Sæson ${s.number}'),
              selected: _selectedSeason == s.number,
              onSelected: (_) => setState(() => _selectedSeason = s.number),
            ),
          );
        },
      ),
    );
  }

  Widget _episodeList() {
    final season = _currentSeason;
    final episodes = season?.episodes ?? const <Episode>[];
    if (episodes.isEmpty) {
      return const SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.tv_off,
          title: 'Ingen afsnit i denne sæson',
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      sliver: SliverList.separated(
        itemCount: episodes.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _EpisodeRow(
          episode: episodes[i],
          autofocus: i == 0,
          onTap: () => _play(episodes[i]),
        ),
      ),
    );
  }
}

/// Poster + title + plot header. Poster sits beside the text on wide layouts,
/// above it on narrow ones.
class _Header extends StatelessWidget {
  const _Header({required this.series, required this.wide});

  final Series series;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final poster = SizedBox(
      width: wide ? 160 : 120,
      child: AspectRatio(
        aspectRatio: 0.62,
        child: NetworkImageBox(
          url: series.poster,
          placeholderIcon: Icons.video_library,
          fit: BoxFit.cover,
          borderRadius: 12,
        ),
      ),
    );

    final meta = <String>[
      if (series.year != null && series.year!.isNotEmpty) series.year!,
      if (series.genre != null && series.genre!.isNotEmpty) series.genre!,
      if (series.rating != null) '★ ${series.rating!.toStringAsFixed(1)}',
    ];

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          series.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            meta.join('  ·  '),
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
        if (series.plot != null && series.plot!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            series.plot!,
            maxLines: wide ? 8 : 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                poster,
                const SizedBox(width: 16),
                Expanded(child: info),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: poster),
                const SizedBox(height: 16),
                info,
              ],
            ),
    );
  }
}

/// A single, D-pad-focusable episode row with a lazily-loaded resume bar.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.onTap,
    this.autofocus = false,
  });

  final Episode episode;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final label = 'S${episode.seasonNumber}E${episode.episodeNumber} · ${episode.title}';
    return FocusRing(
      borderRadius: 12,
      child: FocusableCard(
      autofocus: autofocus,
      onTap: onTap,
      scaleOnFocus: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.play_circle_outline, size: 28, color: Colors.white70),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                if (episode.plot != null && episode.plot!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    episode.plot!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
                _resumeBar(state),
              ],
            ),
          ),
          _downloadButton(context),
        ],
      ),
      ),
    );
  }

  Widget _resumeBar(AppState state) {
    return FutureBuilder<ResumePoint?>(
      future: state.resumeFor('ep:${episode.id}'),
      builder: (context, snap) {
        final point = snap.data;
        if (point == null || point.fraction <= 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: point.fraction,
              minHeight: 4,
              backgroundColor: Colors.white12,
            ),
          ),
        );
      },
    );
  }

  Widget _downloadButton(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    if (!dm.supported) return const SizedBox.shrink();
    final key = 'ep:${episode.id}';
    final sid = context.read<AppState>().active?.id;
    final item = dm.byKey(key, sourceId: sid);
    if (item == null) {
      return IconButton(
        tooltip: 'Download',
        icon: const Icon(Icons.download_outlined),
        onPressed: () => _startDownload(context),
      );
    }
    switch (item.status) {
      case DownloadStatus.completed:
        return IconButton(
          tooltip: 'Hentet — tryk for at slette',
          icon: const Icon(Icons.download_done, color: Colors.greenAccent),
          onPressed: () => dm.remove(key, sourceId: item.sourceId),
        );
      case DownloadStatus.downloading:
        return SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: item.totalBytes > 0 ? item.progress : null,
                strokeWidth: 2,
              ),
              IconButton(
                iconSize: 16,
                icon: const Icon(Icons.close),
                onPressed: () => dm.remove(key, sourceId: item.sourceId),
              ),
            ],
          ),
        );
      case DownloadStatus.queued:
        return IconButton(
          tooltip: 'I kø',
          icon: const Icon(Icons.hourglass_empty),
          onPressed: () => dm.remove(key, sourceId: item.sourceId),
        );
      case DownloadStatus.failed:
        return IconButton(
          tooltip: 'Prøv igen',
          icon: const Icon(Icons.refresh),
          onPressed: () => dm.retry(key, sourceId: item.sourceId),
        );
    }
  }

  void _startDownload(BuildContext context) {
    final source = context.read<AppState>().active;
    if (source == null) return;
    context.read<DownloadManager>().enqueue(DownloadItem(
          key: 'ep:${episode.id}',
          kind: 'series',
          title: episode.title,
          image: episode.poster,
          sourceId: source.id,
          remoteUrl: StreamUrlBuilder.episode(source, episode),
          userAgent: source.userAgent ?? kDefaultUserAgent,
          ext: (episode.containerExtension?.isNotEmpty ?? false)
              ? episode.containerExtension!
              : 'mp4',
        ));
  }
}
