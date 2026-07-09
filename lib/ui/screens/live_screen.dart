import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/live_channel.dart';
import '../../models/media_item.dart';
import '../../services/iptv_errors.dart';
import '../../services/tv_mode.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/media_card.dart';
import '../widgets/skeleton.dart';
import 'add_source_screen.dart';
import 'category_order_screen.dart';
import 'player_screen.dart';

const double _wideBreakpoint = 820;

class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _maybeResumeLastChannel(context, state);
    return Scaffold(
      appBar: AppBar(
        title: Text(state.active?.name ?? 'Live TV'),
        actions: [
          if (state.liveCategories.isNotEmpty)
            IconButton(
              tooltip: 'Rediger rækkefølge',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CategoryOrderScreen()),
              ),
              icon: const Icon(Icons.swap_vert),
            ),
          IconButton(
            tooltip: 'Genindlæs',
            onPressed: state.liveLoading ? null : () => state.loadLive(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.expiryDaysLeft != null) _expiryBanner(state.expiryDaysLeft!),
          Expanded(child: _body(context, state)),
        ],
      ),
    );
  }

  /// "Fortsæt på sidste kanal": once per launch, when the channel list is
  /// ready, auto-open the last-watched channel instead of showing the grid.
  void _maybeResumeLastChannel(BuildContext context, AppState state) {
    if (!resumeLastChannel || state.autoResumedThisSession) return;
    final id = state.lastLiveChannelId;
    final active = state.active;
    if (id == null || active == null || state.channels.isEmpty) return;
    // Rebuild the SAME filtered list (category/favorites/"Alle kanaler") the
    // channel was actually being watched from, not always the full unfiltered
    // list — otherwise next/prev-channel zapping in the resumed session paged
    // through everything instead of just the category the user had open.
    var channels = state.channelsInCategory(state.lastLiveCategoryId);
    var idx = channels.indexWhere((c) => c.id == id);
    if (idx < 0) {
      // The category may have been hidden/renamed, or the channel moved
      // categories on a provider refresh, since it was last watched — fall
      // back to the full list so auto-resume still fires (just without the
      // original category context) instead of silently not resuming at all.
      channels = state.channels;
      idx = channels.indexWhere((c) => c.id == id);
      if (idx < 0) return;
    }
    state.autoResumedThisSession = true; // fire once
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen.live(
          source: active,
          playlist: channels,
          initialIndex: idx,
        ),
      ));
    });
  }

  Widget _expiryBanner(int daysLeft) {
    final text = daysLeft <= 0
        ? 'Dit abonnement er udløbet eller udløber i dag.'
        : 'Dit abonnement udløber om $daysLeft ${daysLeft == 1 ? 'dag' : 'dage'} — husk at forny.';
    return Container(
      width: double.infinity,
      color: const Color(0xFF5A3A00),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 18, color: Colors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppState state) {
    if (state.liveLoading && state.channels.isEmpty) {
      return const SkeletonGrid(aspectRatio: 0.95);
    }
    if (state.liveError != null && state.channels.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        title: 'Kunne ikke hente kanaler',
        message: state.liveError,
        actionLabel: 'Prøv igen',
        onAction: () => state.loadLive(forceRefresh: true),
        secondaryLabel: state.liveErrorAction == IptvErrorAction.switchToXtream
            ? 'Skift til Xtream Codes'
            : null,
        onSecondary: state.liveErrorAction == IptvErrorAction.switchToXtream
            ? () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const AddSourceScreen(startInXtreamMode: true),
                ))
            : null,
      );
    }
    if (state.channels.isEmpty) {
      return const EmptyState(icon: Icons.live_tv, title: 'Ingen kanaler');
    }

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= _wideBreakpoint;
        final rail = _CategoryPane(state: state, wide: wide);
        final grid = _ChannelGrid(state: state);
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
      const _Cat(null, 'Alle kanaler', Icons.apps),
      if (state.hasFavorites) const _Cat(kFavoritesCategoryId, 'Favoritter', Icons.star),
      ...state.orderedLiveCategories.map((c) => _Cat(c.id, c.name, Icons.folder)),
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
                selected: state.liveCategoryId == e.id,
                onSelected: (_) => state.selectLiveCategory(e.id),
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
        final selected = state.liveCategoryId == e.id;
        final count = e.id == null || e.id == kFavoritesCategoryId
            ? null
            : state.liveCountFor(e.id!);
        return FocusRing(
          borderRadius: 10,
          child: ListTile(
            dense: true,
            selected: selected,
            leading: Icon(e.icon, size: 20),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: count != null ? Text('$count', style: const TextStyle(color: Colors.white38)) : null,
            onTap: () => state.selectLiveCategory(e.id),
          ),
        );
      },
    );
  }
}

class _ChannelGrid extends StatelessWidget {
  const _ChannelGrid({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final channels = state.visibleChannels;
    if (channels.isEmpty) {
      return const EmptyState(icon: Icons.tv_off, title: 'Ingen kanaler her');
    }
    return LayoutBuilder(
      builder: (context, c) {
        final cross = (c.maxWidth / 170).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.95,
          ),
          itemCount: channels.length,
          itemBuilder: (context, i) {
            final ch = channels[i];
            return MediaCard(
              title: ch.name,
              imageUrl: ch.logo,
              placeholderIcon: Icons.live_tv,
              imageFit: BoxFit.contain,
              autofocus: i == 0,
              badgeNumber: ch.number,
              isFavorite: state.isFavorite(MediaKind.live, ch.id),
              onToggleFavorite: () => state.toggleFavorite(MediaKind.live, ch.id),
              onTap: () => _play(context, channels, i),
            );
          },
        );
      },
    );
  }

  void _play(BuildContext context, List<LiveChannel> channels, int i) {
    final state = context.read<AppState>();
    state.markWatched(channels[i]);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.live(
        source: state.active!,
        playlist: channels,
        initialIndex: i,
      ),
    ));
  }
}

class _Cat {
  final String? id;
  final String name;
  final IconData icon;
  const _Cat(this.id, this.name, this.icon);
}
