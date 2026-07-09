import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/category.dart';
import '../../models/media_item.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../widgets/focus_ring.dart';

/// Lets the user reorder the live-TV categories (e.g. put [DK] and [TR] on top).
/// Works with touch (drag handle) and a D-pad remote (up / down / to-top
/// buttons). Changes persist immediately, per source.
class CategoryOrderScreen extends StatefulWidget {
  const CategoryOrderScreen({super.key});

  @override
  State<CategoryOrderScreen> createState() => _CategoryOrderScreenState();
}

class _CategoryOrderScreenState extends State<CategoryOrderScreen> {
  late List<IptvCategory> _cats;

  @override
  void initState() {
    super.initState();
    _cats = [...context.read<AppState>().allOrderedLiveCategories];
  }

  void _persist() {
    context.read<AppState>().setLiveCategoryOrder(_cats.map((c) => c.id).toList());
  }

  void _move(int from, int to) {
    if (to < 0 || to >= _cats.length || from == to) return;
    setState(() {
      final item = _cats.removeAt(from);
      _cats.insert(to, item);
    });
    _persist();
  }

  // onReorderItem gives a newIndex already adjusted for the removal.
  void _onReorderItem(int oldIndex, int newIndex) {
    setState(() {
      final item = _cats.removeAt(oldIndex);
      _cats.insert(newIndex, item);
    });
    _persist();
  }

  void _reset() {
    final state = context.read<AppState>();
    state.setLiveCategoryOrder(const []);
    setState(() => _cats = [...state.allOrderedLiveCategories]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rediger rækkefølge'),
        actions: [
          TextButton(
            onPressed: _reset,
            child: const Text('Nulstil'),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Træk kategorierne — eller brug pilene — for at ændre rækkefølgen. '
              'Læg fx [DK] og [TR] øverst. Gemmes automatisk.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                TvPillButton(
                  label: 'Skjul alle',
                  icon: Icons.visibility_off,
                  onPressed: () => context
                      .read<AppState>()
                      .setAllCategoriesHidden(MediaKind.live, true),
                ),
                const SizedBox(width: 10),
                TvPillButton(
                  label: 'Vis alle',
                  icon: Icons.visibility_outlined,
                  onPressed: () => context
                      .read<AppState>()
                      .setAllCategoriesHidden(MediaKind.live, false),
                ),
                Expanded(
                  child: Text(
                    'Skjul alt — og slå kun dét til, du vil se.',
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: _cats.length,
              onReorderItem: _onReorderItem,
              itemBuilder: (context, i) {
                final c = _cats[i];
                final hidden =
                    context.watch<AppState>().isCategoryHidden(c.id);
                final isFirst = i == 0;
                final isLast = i == _cats.length - 1;
                // Plain Row (NOT a ListTile): the row itself must not be a
                // focus stop — a handler-less tile swallows OK and blocks the
                // D-pad from ever reaching the four icon buttons inside it.
                // FocusRing still lights the whole row when any icon has focus.
                return FocusRing(
                  key: ValueKey(c.id),
                  borderRadius: 12,
                  child: Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle,
                                color: Colors.white54),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: hidden
                                  ? const TextStyle(
                                      color: Colors.white38,
                                      decoration: TextDecoration.lineThrough)
                                  : TextStyle(
                                      fontSize: AppTheme.tvFont(14, 15.5)),
                            ),
                          ),
                          IconButton(
                            tooltip:
                                hidden ? 'Vis kategori' : 'Skjul kategori',
                            icon: Icon(
                              hidden
                                  ? Icons.visibility_off
                                  : Icons.visibility_outlined,
                              color: hidden ? Colors.white38 : null,
                            ),
                            onPressed: () => context
                                .read<AppState>()
                                .toggleCategoryHidden(c.id),
                          ),
                          IconButton(
                            tooltip: 'Til toppen',
                            icon: Icon(
                              Icons.vertical_align_top,
                              color: isFirst ? Colors.white24 : null,
                            ),
                            onPressed: isFirst ? () {} : () => _move(i, 0),
                          ),
                          IconButton(
                            tooltip: 'Op',
                            icon: Icon(
                              Icons.keyboard_arrow_up,
                              color: isFirst ? Colors.white24 : null,
                            ),
                            onPressed: isFirst ? () {} : () => _move(i, i - 1),
                          ),
                          IconButton(
                            tooltip: 'Ned',
                            icon: Icon(
                              Icons.keyboard_arrow_down,
                              color: isLast ? Colors.white24 : null,
                            ),
                            onPressed: isLast ? () {} : () => _move(i, i + 1),
                          ),
                        ],
                      ),
                    ),
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
