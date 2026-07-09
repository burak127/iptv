import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/iptv_source.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/focus_ring.dart';
import 'add_source_screen.dart';

/// Lists the user's saved IPTV providers and lets them add, activate or
/// delete a source. Works with both touch and D-pad remotes: each row is a
/// focusable [ListTile] and the delete action opens a confirm dialog.
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sources = state.sources;
    final activeId = state.active?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Kilder')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addSource(context),
        icon: const Icon(Icons.add),
        label: const Text('Tilføj kilde'),
      ),
      body: sources.isEmpty
          ? EmptyState(
              icon: Icons.playlist_add,
              title: 'Ingen kilder endnu',
              message: 'Tilføj en M3U-playliste eller Xtream Codes-konto for at komme i gang.',
              actionLabel: 'Tilføj kilde',
              onAction: () => _addSource(context),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: sources.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final source = sources[i];
                return _SourceTile(
                  source: source,
                  isActive: source.id == activeId,
                  autofocus: i == 0,
                );
              },
            ),
    );
  }

  void _addSource(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddSourceScreen()),
    );
  }
}

/// A single row in the sources list.
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.isActive,
    this.autofocus = false,
  });

  final IptvSource source;
  final bool isActive;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return FocusRing(
      borderRadius: 12,
      child: Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        autofocus: autofocus,
        leading: Icon(
          source.isXtream ? Icons.vpn_key : Icons.playlist_play,
          size: 28,
        ),
        title: Text(
          source.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _subtitle(source),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              const Chip(
                label: Text('Aktiv'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            IconButton(
              tooltip: 'Slet kilde',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
        // Keep the active row focusable on TV (a null onTap would make the
        // Delete icon its only focus stop).
        onTap: isActive ? () {} : () => state.setActive(source),
      ),
      ),
    );
  }

  /// M3U → the playlist URL. Xtream → "host · username".
  String _subtitle(IptvSource source) {
    if (source.isXtream) {
      final host = source.host ?? '';
      final user = source.username ?? '';
      return user.isEmpty ? host : '$host · $user';
    }
    return source.m3uUrl ?? '';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final state = context.read<AppState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Slet kilde?'),
        content: Text('Vil du fjerne "${source.name}"? Dette kan ikke fortrydes.'),
        actions: [
          TextButton(
            // The SAFE action is the remote's default — not the destructive one.
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuller'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Slet'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.removeSource(source);
    }
  }
}
