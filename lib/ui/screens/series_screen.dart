import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/media_item.dart';
import '../../models/series.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/media_card.dart';
import '../widgets/skeleton.dart';
import '../screens/category_visibility_screen.dart';
import '../screens/series_detail_screen.dart';

const double _wideBreakpoint = 820;

/// Browse the active source's TV series: a category rail (wide) or chip row
/// (narrow) beside a poster grid. Xtream-only; tapping a poster opens the
/// [SeriesDetailScreen] for season/episode selection.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key});

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().ensureSeries();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Serier'),
        actions: [
          if (state.seriesCategories.isNotEmpty)
            categoryVisibilityAction(context, MediaKind.series),
          IconButton(
            tooltip: 'Genindlæs',
            onPressed: state.seriesLoading
                ? null
                : () => state.ensureSeries(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(context, state),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (!state.activeIsXtream) {
      return const EmptyState(
        icon: Icons.video_library,
        title: 'Serier kræver Xtream Codes',
        message: 'Den aktive udbyder understøtter ikke serier.',
      );
    }
    if (state.seriesLoading && state.series.isEmpty) {
      return const SkeletonGrid(aspectRatio: 0.62);
    }
    if (state.seriesError != null && state.series.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        title: 'Kunne ikke hente serier',
        message: state.seriesError,
        actionLabel: 'Prøv igen',
        onAction: () => state.ensureSeries(forceRefresh: true),
      );
    }
    if (state.series.isEmpty) {
      return const EmptyState(icon: Icons.video_library, title: 'Ingen serier');
    }

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _wideBreakpoint;
        final rail = _CategoryPane(state: state, wide: wide);
        final grid = _SeriesGrid(state: state);
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
      const _Cat(null, 'Alle serier', Icons.apps),
      if (state.hasFavorites) const _Cat(kFavoritesCategoryId, 'Favoritter', Icons.star),
      ...state.visibleSeriesCategories.map((c) => _Cat(c.id, c.name, Icons.folder)),
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
                selected: state.seriesCategoryId == e.id,
                onSelected: (_) => state.selectSeriesCategory(e.id),
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
        final selected = state.seriesCategoryId == e.id;
        return FocusRing(
          borderRadius: 10,
          child: ListTile(
            dense: true,
            selected: selected,
            leading: Icon(e.icon, size: 20),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => state.selectSeriesCategory(e.id),
          ),
        );
      },
    );
  }
}

class _SeriesGrid extends StatelessWidget {
  const _SeriesGrid({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.visibleSeries;
    if (items.isEmpty) {
      return const EmptyState(icon: Icons.video_library, title: 'Ingen serier her');
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
          itemCount: items.length,
          itemBuilder: (context, i) {
            final s = items[i];
            return MediaCard(
              title: s.name,
              imageUrl: s.poster,
              placeholderIcon: Icons.video_library,
              imageFit: BoxFit.cover,
              aspectRatio: 0.62,
              autofocus: i == 0,
              isFavorite: state.isFavorite(MediaKind.series, s.id),
              onToggleFavorite: () => state.toggleFavorite(MediaKind.series, s.id),
              onTap: () => _open(context, s),
            );
          },
        );
      },
    );
  }

  void _open(BuildContext context, Series series) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SeriesDetailScreen(series: series),
    ));
  }
}

class _Cat {
  final String? id;
  final String name;
  final IconData icon;
  const _Cat(this.id, this.name, this.icon);
}
