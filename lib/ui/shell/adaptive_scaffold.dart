import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/download_manager.dart';
import '../../services/tv_mode.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../widgets/focusable_card.dart';
import '../screens/downloads_screen.dart';
import '../screens/guide_screen.dart';
import '../screens/live_screen.dart';
import '../screens/movies_screen.dart';
import '../screens/search_screen.dart';
import '../screens/series_screen.dart';
import '../screens/settings_screen.dart';

const double _wideBreakpoint = 820;

class _Dest {
  final String label;
  final IconData icon;
  final Widget Function() builder;
  const _Dest(this.label, this.icon, this.builder);
}

/// TV navigation rail with an unmissable focus ring on every destination.
class _TvRail extends StatelessWidget {
  const _TvRail({
    required this.dests,
    required this.index,
    required this.onSelect,
  });

  final List<_Dest> dests;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 124,
      color: AppTheme.surfaceAlt,
      child: FocusTraversalGroup(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          children: [
            for (var i = 0; i < dests.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _railItem(i, dests[i], selected: i == index),
              ),
          ],
        ),
      ),
    );
  }

  Widget _railItem(int i, _Dest d, {required bool selected}) {
    final color = selected ? AppTheme.focus : Colors.white70;
    return FocusableCard(
      onTap: () => onSelect(i),
      scaleOnFocus: false,
      borderRadius: 12,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
            decoration: selected
                ? BoxDecoration(
                    color: AppTheme.seed.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(14),
                  )
                : null,
            child: Icon(d.icon, size: 24, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            d.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              color: color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-level navigation shell: NavigationRail on wide/TV, NavigationBar on
/// phone, over a lazily-built IndexedStack that preserves per-tab state. VOD /
/// Series destinations only appear for Xtream sources.
class AdaptiveScaffold extends StatefulWidget {
  const AdaptiveScaffold({super.key});

  @override
  State<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends State<AdaptiveScaffold> {
  int _index = 0;
  String _selectedLabel = 'Live';
  final Set<int> _visited = {0};
  DateTime? _lastBack;

  List<_Dest> _destinations(bool xtream, bool showDownloads) => [
        _Dest('Live', Icons.live_tv, () => const LiveScreen()),
        if (xtream) _Dest('Guide', Icons.calendar_view_day_outlined, () => const GuideScreen()),
        if (xtream) _Dest('Film', Icons.movie_outlined, () => const MoviesScreen()),
        if (xtream) _Dest('Serier', Icons.video_library_outlined, () => const SeriesScreen()),
        if (showDownloads) _Dest('Downloads', Icons.download_outlined, () => const DownloadsScreen()),
        _Dest('Søg', Icons.search, () => const SearchScreen()),
        _Dest('Indstillinger', Icons.settings_outlined, () => const SettingsScreen()),
      ];

  void _select(int i, List<_Dest> dests) {
    setState(() {
      _index = i;
      _selectedLabel = dests[i].label;
      _visited.add(i);
      _lastBack = null; // any navigation clears a stale exit-arm
    });
    // Re-grab the search field's D-pad focus every time — see the doc on
    // SearchScreen.activated for why this can't just rely on autofocus.
    if (dests[i].label == 'Søg') SearchScreen.activated.value++;
  }

  Widget _lazyStack(List<_Dest> dests) {
    return IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < dests.length; i++)
          _visited.contains(i) ? dests[i].builder() : const SizedBox.shrink(),
      ],
    );
  }

  Future<void> _handleBack(List<_Dest> dests) async {
    if (Navigator.of(context).canPop()) return; // a pushed route handles it
    if (_index != 0) {
      _select(0, dests);
      return;
    }
    final now = DateTime.now();
    if (_lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2)) {
      await SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tryk tilbage igen for at afslutte'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final xtream = context.watch<AppState>().activeIsXtream;
    final dm = context.watch<DownloadManager>();
    final dests = _destinations(xtream, dm.supported && dm.items.isNotEmpty);
    // Resolve the selected destination by identity so a shrinking list
    // (xtream→m3u drops Film/Serier) can't silently teleport the user.
    var idx = dests.indexWhere((d) => d.label == _selectedLabel);
    if (idx < 0) idx = 0;
    _index = idx;
    _selectedLabel = dests[_index].label;
    _visited.removeWhere((i) => i >= dests.length);
    _visited.add(_index);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack(dests);
      },
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= _wideBreakpoint) {
            return Scaffold(
              body: Padding(
                // TVs crop ~3-5% at the edges (overscan) — inset the shell so
                // the rail and grid edges are never cut off.
                padding: isTvMode
                    ? const EdgeInsets.fromLTRB(24, 16, 24, 16)
                    : EdgeInsets.zero,
                child: Row(
                  children: [
                    // TV: Material's NavigationRail focus highlight is
                    // imperceptible at 10 feet — use our own focus-ringed rail.
                    if (isTvMode)
                      _TvRail(
                        dests: dests,
                        index: _index,
                        onSelect: (i) => _select(i, dests),
                      )
                    else
                      NavigationRail(
                        selectedIndex: _index,
                        onDestinationSelected: (i) => _select(i, dests),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final d in dests)
                            NavigationRailDestination(
                              icon: Icon(d.icon),
                              label: Text(d.label),
                            ),
                        ],
                      ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _lazyStack(dests)),
                  ],
                ),
              ),
            );
          }
          return Scaffold(
            body: _lazyStack(dests),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => _select(i, dests),
              destinations: [
                for (final d in dests)
                  NavigationDestination(icon: Icon(d.icon), label: d.label),
              ],
            ),
          );
        },
      ),
    );
  }
}
