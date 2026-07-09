import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/media_item.dart';
import '../../state/app_state.dart';
import '../widgets/focus_ring.dart';
import '../widgets/tv_text_field.dart';

/// Pick which movie/series categories are visible. Built for providers with
/// 100+ categories: "Skjul alle", then enable the handful you actually watch.
class CategoryVisibilityScreen extends StatefulWidget {
  const CategoryVisibilityScreen({super.key, required this.kind});

  final MediaKind kind;

  @override
  State<CategoryVisibilityScreen> createState() =>
      _CategoryVisibilityScreenState();
}

class _CategoryVisibilityScreenState extends State<CategoryVisibilityScreen> {
  String _filter = '';
  final _filterCtrl = TextEditingController();

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
        MediaKind.live => 'Vælg kanal-kategorier',
        MediaKind.vod => 'Vælg film-kategorier',
        MediaKind.series => 'Vælg serie-kategorier',
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final all = switch (widget.kind) {
      MediaKind.live => state.liveCategories,
      MediaKind.vod => state.vodCategories,
      MediaKind.series => state.seriesCategories,
    };
    final q = _filter.toLowerCase().trim();
    final cats = q.isEmpty
        ? all
        : all.where((c) => c.name.toLowerCase().contains(q)).toList();
    final hiddenCount =
        all.where((c) => state.isCategoryHidden(c.id, kind: widget.kind)).length;

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${all.length - hiddenCount} af ${all.length} kategorier vises',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ),
                TvPillButton(
                  label: 'Skjul alle',
                  icon: Icons.visibility_off,
                  onPressed: () =>
                      state.setAllCategoriesHidden(widget.kind, true),
                ),
                const SizedBox(width: 8),
                TvPillButton(
                  label: 'Vis alle',
                  icon: Icons.visibility_outlined,
                  onPressed: () =>
                      state.setAllCategoriesHidden(widget.kind, false),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: DpadEscape(
              // TvTextInput: focus shows a ring; the keyboard only opens on
              // OK — merely stepping over the field must not pop the IME.
              child: TvTextInput(
                controller: _filterCtrl,
                builder: (context, node) => TextField(
                  controller: _filterCtrl,
                  focusNode: node,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Søg kategori…',
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: cats.length,
              itemBuilder: (context, i) {
                final c = cats[i];
                final hidden = state.isCategoryHidden(c.id, kind: widget.kind);
                return FocusRing(
                  borderRadius: 10,
                  child: SwitchListTile(
                    dense: true,
                    value: !hidden,
                    title: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: hidden
                          ? const TextStyle(color: Colors.white38)
                          : null,
                    ),
                    onChanged: (_) =>
                        state.toggleCategoryHidden(c.id, kind: widget.kind),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Convenience for app-bar actions.
IconButton categoryVisibilityAction(BuildContext context, MediaKind kind) {
  return IconButton(
    tooltip: 'Vælg kategorier',
    icon: const Icon(Icons.visibility_outlined),
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CategoryVisibilityScreen(kind: kind),
      ),
    ),
  );
}

