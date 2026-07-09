import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/guide_entry.dart';
import '../../models/live_channel.dart';
import '../../services/iptv_errors.dart';
import '../../services/stream_url_builder.dart';
import '../../services/tv_mode.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import 'player_screen.dart';

const double _wideBreakpoint = 820;

/// Full EPG guide: pick a channel, browse its programmes per day, play live or
/// catch up on past programmes where the provider allows it (tv_archive).
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  Map<String, List<GuideEntry>>? _guide;
  bool _loading = false;
  String? _error;
  LiveChannel? _selected;
  int _dayOffset = 0; // -2..+1, 0 = today

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    final state = context.read<AppState>();
    final s = state.active;
    if (s == null || !s.isXtream || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final g = await state.repository.loadGuide(s, forceRefresh: force);
      if (!mounted) return;
      setState(() {
        _guide = g;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = IptvErrors.map(e).message;
        _loading = false;
      });
    }
  }

  List<GuideEntry> _entriesFor(LiveChannel ch) {
    final id = ch.epgChannelId?.toLowerCase().trim();
    if (id == null || id.isEmpty || _guide == null) return const [];
    return _guide![id] ?? const [];
  }

  // Memoized set of channel ids that actually have guide programmes. The
  // toLowerCase/trim + map lookup per channel is done ONCE per guide/catalog
  // change — not on every D-pad setState or AppState notification, which used to
  // re-scan the whole channel list (two string allocs each) every rebuild.
  Set<String>? _epgChannelIds;
  Map<String, List<GuideEntry>>? _epgGuideRef;
  List<LiveChannel>? _epgChannelsRef;

  Set<String> _channelIdsWithEpg(AppState state) {
    final base = state.channels; // stable identity until a catalog reload
    if (identical(_epgGuideRef, _guide) &&
        identical(_epgChannelsRef, base) &&
        _epgChannelIds != null) {
      return _epgChannelIds!;
    }
    _epgGuideRef = _guide;
    _epgChannelsRef = base;
    final ids = <String>{};
    if (_guide != null) {
      for (final c in base) {
        if (_entriesFor(c).isNotEmpty) ids.add(c.id);
      }
    }
    return _epgChannelIds = ids;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Guide'),
        actions: [
          IconButton(
            tooltip: 'Opdater guide',
            onPressed: _loading ? null : () => _load(force: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(state),
    );
  }

  Widget _body(AppState state) {
    if (!state.activeIsXtream) {
      return const EmptyState(
        icon: Icons.calendar_view_day,
        title: 'Guiden kræver en Xtream-kilde',
      );
    }
    if (_loading && _guide == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Henter programguide…\n(første gang kan tage et øjeblik)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
    if (_error != null && _guide == null) {
      return EmptyState(
        icon: Icons.error_outline,
        iconColor: Colors.redAccent,
        title: 'Kunne ikke hente guiden',
        message: _error,
        actionLabel: 'Prøv igen',
        onAction: () => _load(force: true),
      );
    }
    if (_guide == null) {
      return const EmptyState(icon: Icons.calendar_view_day, title: 'Ingen guide-data');
    }

    final withEpg = _channelIdsWithEpg(state);
    final channels =
        state.visibleChannels.where((c) => withEpg.contains(c.id)).toList();
    if (channels.isEmpty) {
      return const EmptyState(
        icon: Icons.tv_off,
        title: 'Ingen kanaler med programdata',
        message: 'Udbyderens guide matcher ikke kanalernes EPG-id.',
      );
    }
    _selected ??= channels.first;

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= _wideBreakpoint;
      final rail = _channelRail(channels);
      final detail = _programmePane();
      if (wide) {
        return Row(children: [
          SizedBox(width: 300, child: rail),
          const VerticalDivider(width: 1),
          Expanded(child: detail),
        ]);
      }
      return Column(children: [
        SizedBox(height: 64, child: _channelStrip(channels)),
        const Divider(height: 1),
        Expanded(child: detail),
      ]);
    });
  }

  Widget _channelRail(List<LiveChannel> channels) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final ch = channels[i];
        final now = _nowNextLabel(ch);
        return FocusRing(
          borderRadius: 10,
          child: ListTile(
            dense: !isTvMode,
            selected: _selected?.id == ch.id,
            leading: Text(ch.number != null ? '${ch.number}' : '',
                style: const TextStyle(color: Colors.white60)),
            title: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: now == null
                ? null
                : Text(now,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: AppTheme.tvFont(11, 14))),
            onTap: () => setState(() => _selected = ch),
          ),
        );
      },
    );
  }

  Widget _channelStrip(List<LiveChannel> channels) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final ch = channels[i];
        return FocusRing(
          borderRadius: 20,
          child: ChoiceChip(
            label: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: _selected?.id == ch.id,
            onSelected: (_) => setState(() => _selected = ch),
          ),
        );
      },
    );
  }

  String? _nowNextLabel(LiveChannel ch) {
    final nowUtc = DateTime.now().toUtc();
    for (final e in _entriesFor(ch)) {
      if (e.isLiveAt(nowUtc)) return 'Nu: ${e.title}';
    }
    return null;
  }

  Widget _programmePane() {
    final ch = _selected;
    if (ch == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day)
        .add(Duration(days: _dayOffset));
    final dayEnd = day.add(const Duration(days: 1));

    final entries = _entriesFor(ch).where((e) {
      final localStart = e.startUtc.toLocal();
      return localStart.isAfter(day.subtract(const Duration(minutes: 1))) &&
          localStart.isBefore(dayEnd);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(ch.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _playLive(ch),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Se live'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final d in [-2, -1, 0, 1])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FocusRing(
                    borderRadius: 20,
                    child: ChoiceChip(
                      label: Text(_dayLabel(d)),
                      selected: _dayOffset == d,
                      onSelected: (_) => setState(() => _dayOffset = d),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(
                  icon: Icons.schedule, title: 'Ingen programmer denne dag')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: entries.length,
                  itemBuilder: (context, i) =>
                      _programmeTile(ch, entries[i]),
                ),
        ),
      ],
    );
  }

  String _dayLabel(int offset) {
    switch (offset) {
      case -2:
        return 'I forgårs';
      case -1:
        return 'I går';
      case 0:
        return 'I dag';
      default:
        return 'I morgen';
    }
  }

  Widget _programmeTile(LiveChannel ch, GuideEntry e) {
    final nowUtc = DateTime.now().toUtc();
    final isNow = e.isLiveAt(nowUtc);
    final isPast = e.endUtc.isBefore(nowUtc);
    final canCatchUp = isPast && _withinArchive(ch, e);
    final start = e.startUtc.toLocal();
    final end = e.endUtc.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');

    return FocusRing(
      borderRadius: 10,
      child: ListTile(
        dense: true,
        enabled: isNow || canCatchUp || !isPast,
        leading: SizedBox(
          width: 44,
          child: Text('${two(start.hour)}:${two(start.minute)}',
              style: TextStyle(
                  color: isNow ? Theme.of(context).colorScheme.primary : Colors.white54,
                  fontWeight: isNow ? FontWeight.w700 : FontWeight.w400)),
        ),
        title: Text(
          e.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isNow ? FontWeight.w600 : FontWeight.w400,
            color: isPast && !canCatchUp ? Colors.white38 : null,
          ),
        ),
        subtitle: (e.description ?? '').isNotEmpty
            ? Text(e.description!,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.tvFont(11, 14)))
            : null,
        trailing: isNow
            ? const Icon(Icons.live_tv, size: 18, color: Colors.redAccent)
            : canCatchUp
                ? const Icon(Icons.replay, size: 18)
                : Text('${two(end.hour)}:${two(end.minute)}',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: AppTheme.tvFont(11, 13))),
        onTap: () {
          if (isNow) {
            _playLive(ch);
          } else if (canCatchUp) {
            _playCatchUp(ch, e);
          }
        },
      ),
    );
  }

  bool _withinArchive(LiveChannel ch, GuideEntry e) {
    if (!ch.tvArchive || e.timeshiftStart.isEmpty) return false;
    final days = ch.tvArchiveDuration > 0 ? ch.tvArchiveDuration : 1;
    return e.startUtc
        .isAfter(DateTime.now().toUtc().subtract(Duration(days: days)));
  }

  void _playLive(LiveChannel ch) {
    final state = context.read<AppState>();
    final source = state.active;
    if (source == null) return;
    final list = state.visibleChannels;
    var idx = list.indexWhere((c) => c.id == ch.id);
    state.markWatched(ch);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.live(
        source: source,
        playlist: idx >= 0 ? list : [ch],
        initialIndex: idx >= 0 ? idx : 0,
      ),
    ));
  }

  void _playCatchUp(LiveChannel ch, GuideEntry e) {
    final source = context.read<AppState>().active;
    if (source == null) return;
    final url = StreamUrlBuilder.timeshift(
        source, ch, e.durationMinutes.clamp(1, 24 * 60), e.timeshiftStart);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.onDemand(
        source: source,
        url: url,
        title: '${e.title} · ${ch.name}',
        durationHint: e.durationMinutes * 60,
      ),
    ));
  }
}
