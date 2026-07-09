import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/live_channel.dart';
import '../../models/media_item.dart';
import '../../models/movie.dart';
import '../../models/series.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/media_card.dart';
import '../widgets/tv_text_field.dart';
import 'movie_detail_screen.dart';
import 'player_screen.dart';
import 'series_detail_screen.dart';

/// Debounce window before a keystroke turns into a query.
const Duration _kDebounce = Duration(milliseconds: 250);

/// Full-text search across live channels, movies and series for the active
/// source. Ensures VOD + series are loaded so the local [AppState.search] index
/// covers all three kinds, then renders matches as a responsive poster grid.
/// Works with both a D-pad remote (autofocused field + focusable cards) and
/// touch.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Bumped by AdaptiveScaffold whenever the Søg tab becomes the active
  /// IndexedStack index. IndexedStack keeps this screen's State alive for the
  /// whole app session, so TvTextInput's one-shot initState autofocus only
  /// ever wins on the very first visit — without this signal, navigating away
  /// and back left D-pad focus wherever it was last, reintroducing the "where
  /// is the field" friction the autofocus fix was meant to eliminate.
  static final ValueNotifier<int> activated = ValueNotifier(0);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  String _query = '';
  List<MediaItem> _results = const [];
  // Set when a search ran while the VOD/series index was still loading (e.g.
  // a provider with 100+ categories on a slow TV box) -- "no results" in that
  // window is a false negative, not a real miss. Cleared + silently re-run
  // once loading finishes, in build() below.
  bool _searchedWhileLoading = false;

  @override
  void initState() {
    super.initState();
    // Warm the VOD + series indexes so search spans movies and series too
    // (live is already loaded for the active source).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      state.ensureVod();
      state.ensureSeries();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_kDebounce, () => _runSearch(value));
  }

  void _runSearch(String value) {
    if (!mounted) return;
    final query = value.trim();
    final state = context.read<AppState>();
    _searchedWhileLoading =
        query.isNotEmpty && (state.vodLoading || state.seriesLoading);
    setState(() {
      _query = query;
      _results = query.isEmpty ? const [] : state.search(query);
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _query = '';
      _results = const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final stillLoading = state.vodLoading || state.seriesLoading;
    // The index finished loading after a search ran against an incomplete
    // one -- silently re-run so a real match doesn't stay hidden behind a
    // stale "Ingen resultater". Deferred a frame since this runs mid-build.
    if (_searchedWhileLoading && !stillLoading) {
      _searchedWhileLoading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch(_query);
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: DpadEscape(
          child: TvTextInput(
            // Only interactive control on this screen when it's empty — grab
            // focus immediately so the remote can press OK and start typing
            // right away, no extra "where is the field" navigation needed.
            // Re-grabs on every subsequent visit too via SearchScreen.activated.
            autofocus: true,
            refocusSignal: SearchScreen.activated,
            controller: _controller,
            // TvKeyboard's "FÆRDIG" has no field of its own to fire
            // onSubmitted from — the reactive debounced onChanged below
            // should already run a search per keystroke, but this makes
            // "press done" also reliably kick one off immediately.
            onSubmitted: () => _runSearch(_controller.text),
            builder: (context, node) => TextField(
              controller: _controller,
              focusNode: node,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Søg i kanaler, film og serier',
                border: InputBorder.none,
                suffixIcon: _query.isEmpty && _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Ryd',
                        onPressed: _clear,
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
        ),
      ),
      body: _body(context, stillLoading),
    );
  }

  Widget _body(BuildContext context, bool stillLoading) {
    if (_query.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        title: 'Søg i dit indhold',
        message: 'Find kanaler, film og serier fra din aktive kilde.',
      );
    }
    if (_results.isEmpty) {
      // Distinguish "the VOD/series index isn't fully loaded yet" (a false
      // negative -- see _searchedWhileLoading) from a genuine no-match; both
      // looked identical before, so a real result could appear to just be
      // missing on a slow TV box mid-load.
      if (stillLoading) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Henter film og serier…',
                  style: TextStyle(color: Colors.white54)),
            ],
          ),
        );
      }
      return const EmptyState(
        icon: Icons.search_off,
        title: 'Ingen resultater',
      );
    }
    return _ResultsGrid(results: _results, onOpen: _open);
  }

  void _open(BuildContext context, MediaItem item) {
    final state = context.read<AppState>();
    switch (item.kind) {
      case MediaKind.live:
        final channel = item as LiveChannel;
        state.markWatched(channel);
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerScreen.live(
            source: state.active!,
            playlist: [channel],
            initialIndex: 0,
          ),
        ));
        break;
      case MediaKind.vod:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MovieDetailScreen(movie: item as Movie),
        ));
        break;
      case MediaKind.series:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SeriesDetailScreen(series: item as Series),
        ));
        break;
    }
  }
}

/// Responsive poster grid of mixed [MediaItem] results, with the right
/// placeholder icon per kind.
class _ResultsGrid extends StatelessWidget {
  const _ResultsGrid({required this.results, required this.onOpen});

  final List<MediaItem> results;
  final void Function(BuildContext, MediaItem) onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return LayoutBuilder(
      builder: (context, c) {
        final cross = (c.maxWidth / 160).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.7,
          ),
          itemCount: results.length,
          itemBuilder: (context, i) {
            final item = results[i];
            return MediaCard(
              title: item.name,
              imageUrl: item.imageUrl,
              placeholderIcon: _iconFor(item.kind),
              imageFit: BoxFit.cover,
              aspectRatio: 0.7,
              autofocus: i == 0,
              isFavorite: state.isFavorite(item.kind, item.id),
              onToggleFavorite: () => state.toggleFavorite(item.kind, item.id),
              onTap: () => onOpen(context, item),
            );
          },
        );
      },
    );
  }

  static IconData _iconFor(MediaKind kind) {
    switch (kind) {
      case MediaKind.live:
        return Icons.live_tv;
      case MediaKind.vod:
        return Icons.movie;
      case MediaKind.series:
        return Icons.video_library;
    }
  }
}
