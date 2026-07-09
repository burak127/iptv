import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/media_item.dart';
import '../../models/movie.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/media_card.dart';
import '../widgets/skeleton.dart';
import 'category_visibility_screen.dart';
import 'movie_detail_screen.dart';

const double _wideBreakpoint = 820;

/// Browse VOD movies for the active Xtream source: a category pane (rail on
/// wide screens, chips on narrow) plus a poster grid of [AppState.visibleMovies].
/// Works with both D-pad focus traversal and touch.
class MoviesScreen extends StatefulWidget {
  const MoviesScreen({super.key});

  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().ensureVod();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Film'),
        actions: [
          if (state.vodCategories.isNotEmpty)
            categoryVisibilityAction(context, MediaKind.vod),
          IconButton(
            tooltip: 'Genindlæs',
            onPressed:
                state.vodLoading ? null : () => state.ensureVod(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(context, state),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (state.vodLoading && state.movies.isEmpty) {
      return const SkeletonGrid(aspectRatio: 0.62);
    }
    if (state.vodError != null && state.movies.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        title: 'Kunne ikke hente film',
        message: state.vodError,
        actionLabel: 'Prøv igen',
        onAction: () => state.ensureVod(forceRefresh: true),
      );
    }
    if (state.movies.isEmpty) {
      return const EmptyState(icon: Icons.movie_outlined, title: 'Ingen film');
    }

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _wideBreakpoint;
        final rail = _CategoryPane(state: state, wide: wide);
        final grid = _MovieGrid(state: state);
        if (wide) {
          return Row(
            children: [
              SizedBox(width: 260, child: rail),
              const VerticalDivider(width: 1),
              Expanded(child: grid),
            ],
          );
        }
        return Column(
          children: [rail, const Divider(height: 1), Expanded(child: grid)],
        );
      },
    );
  }
}

class _CategoryPane extends StatelessWidget {
  const _CategoryPane({required this.state, required this.wide});
  final AppState state;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final entries = <_Cat>[
      const _Cat(null, 'Alle', Icons.apps),
      if (state.hasFavorites) const _Cat(kFavoritesCategoryId, 'Favoritter', Icons.star),
      ...state.visibleVodCategories.map((c) => _Cat(c.id, c.name, Icons.folder)),
    ];

    if (!wide) {
      return SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final e = entries[i];
            return FocusRing(
              borderRadius: 20,
              child: ChoiceChip(
                label: Text(e.name),
                selected: state.vodCategoryId == e.id,
                onSelected: (_) => state.selectVodCategory(e.id),
              ),
            );
          },
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final e = entries[i];
        final selected = state.vodCategoryId == e.id;
        return FocusRing(
          borderRadius: 10,
          child: ListTile(
            dense: true,
            selected: selected,
            leading: Icon(e.icon, size: 20),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => state.selectVodCategory(e.id),
          ),
        );
      },
    );
  }
}

class _MovieGrid extends StatelessWidget {
  const _MovieGrid({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final movies = state.visibleMovies;
    if (movies.isEmpty) {
      return const EmptyState(icon: Icons.movie_outlined, title: 'Ingen film her');
    }
    return LayoutBuilder(
      builder: (context, c) {
        final cross = (c.maxWidth / 160).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.62,
          ),
          itemCount: movies.length,
          itemBuilder: (context, i) {
            final m = movies[i];
            return MediaCard(
              title: m.name,
              subtitle: m.year,
              imageUrl: m.poster,
              placeholderIcon: Icons.movie,
              imageFit: BoxFit.cover,
              aspectRatio: 0.62,
              autofocus: i == 0,
              isFavorite: state.isFavorite(MediaKind.vod, m.id),
              onToggleFavorite: () => state.toggleFavorite(MediaKind.vod, m.id),
              onTap: () => _open(context, m, movies),
            );
          },
        );
      },
    );
  }

  void _open(BuildContext context, Movie movie, List<Movie> siblings) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MovieDetailScreen(movie: movie, siblingMovies: siblings),
    ));
  }
}

class _Cat {
  final String? id;
  final String name;
  final IconData icon;
  const _Cat(this.id, this.name, this.icon);
}
