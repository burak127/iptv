import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/tv_mode.dart';
import '../../theme.dart';
import 'tv_keyboard.dart';

/// Wraps content containing single-line text fields so the D-pad Up/Down keys
/// move focus OUT of a focused field instead of being swallowed by the caret.
///
/// On Android TV a focused [TextField] consumes the vertical arrow keys (for
/// caret movement), which traps focus — the remote appears "dead". Remapping
/// Up/Down to a [DirectionalFocusIntent] here (Left/Right still edit text)
/// lets the user navigate away. Placed closer to the field than the app-level
/// DefaultTextEditingShortcuts, so it wins.
class DpadEscape extends StatelessWidget {
  const DpadEscape({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowUp):
            DirectionalFocusIntent(TraversalDirection.up),
        SingleActivator(LogicalKeyboardKey.arrowDown):
            DirectionalFocusIntent(TraversalDirection.down),
      },
      child: child,
    );
  }
}

/// D-pad-friendly text-field shell.
///
/// A focused Flutter [TextField] opens the soft keyboard the moment it gains
/// focus — with D-pad traversal that means merely stepping OVER a field pops
/// the keyboard (the "keyboard opens by itself" TV bug). This wrapper makes
/// the field a two-step control, like Android TV's own settings:
///
///  * D-pad traversal lands on this shell (clear focus ring, NO keyboard);
///  * OK/Enter (or a direct tap on touch devices) enters the actual field and
///    only then opens the keyboard.
///
/// The wrapped field must use the [FocusNode] handed to [builder].
class TvTextInput extends StatefulWidget {
  const TvTextInput({
    super.key,
    required this.builder,
    this.autofocus = false,
    this.refocusSignal,
    this.controller,
    this.onSubmitted,
  });

  /// Builds the field, wiring the given node to its `focusNode`.
  final Widget Function(BuildContext context, FocusNode fieldNode) builder;

  /// When set AND running on TV, OK opens [TvKeyboard] (our own in-Flutter
  /// on-screen keyboard) instead of focusing the real field — Android TV's
  /// SYSTEM soft keyboard has long-standing, unresolved D-pad navigation bugs
  /// on real hardware (the keyboard appears but Left/Right/OK on its own keys
  /// don't work), which is an engine/platform limitation no amount of app-side
  /// code can fix. Optional and backward-compatible: omit it to keep the old
  /// behavior (real field + system keyboard) — used for touch/desktop, where
  /// the system keyboard works fine.
  final TextEditingController? controller;

  /// Called when TvKeyboard's "done" key is pressed -- e.g. to run a search
  /// immediately rather than relying only on the reactive debounced
  /// TextField.onChanged the caller's builder presumably already wires up.
  /// Native-keyboard fields (touch/desktop) already get this via
  /// TextField.onSubmitted on the real field instead; this is specifically
  /// for the TvKeyboard path, which has no such callback of its own.
  final VoidCallback? onSubmitted;

  /// When true, the shell explicitly grabs focus once this widget first
  /// builds (e.g. the search screen's only control) — NOT via [Focus]'s own
  /// autofocus, which Flutter silently discards whenever the surrounding
  /// FocusScope already has a focused child (true here: IndexedStack keeps
  /// every visited tab, and its previously-focused nav-rail item, mounted).
  /// An explicit [FocusNode.requestFocus] always wins instead.
  final bool autofocus;

  /// Re-grabs focus every time this fires — needed because a screen kept
  /// alive in an IndexedStack (e.g. the search tab) only runs [State.initState]
  /// once per app session, so [autofocus] alone only wins on the very FIRST
  /// visit; navigating away and back leaves focus wherever it was left. Pass a
  /// [Listenable] the host screen bumps whenever it becomes the active tab
  /// again (only meaningful together with `autofocus: true`).
  final Listenable? refocusSignal;

  @override
  State<TvTextInput> createState() => _TvTextInputState();
}

class _TvTextInputState extends State<TvTextInput> {
  final FocusNode _shell = FocusNode(debugLabel: 'TvTextInput.shell');
  final FocusNode _field =
      FocusNode(debugLabel: 'TvTextInput.field', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    _shell.addListener(_refresh);
    _field.addListener(_refresh);
    if (widget.autofocus) {
      _requestShellFocus();
      widget.refocusSignal?.addListener(_requestShellFocus);
    }
  }

  void _requestShellFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shell.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.refocusSignal?.removeListener(_requestShellFocus);
    _shell.dispose();
    _field.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  KeyEventResult _onShellKey(FocusNode node, KeyEvent e) {
    // Only react when the shell itself is focused — while the inner field is
    // being edited, Enter must reach the field (onSubmitted), not us.
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
      if (isTvMode && widget.controller != null) {
        _showKeyboard();
      } else {
        _field.requestFocus(); // opens the system keyboard — deliberately, on OK
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showKeyboard() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => TvKeyboard(
        controller: widget.controller!,
        onDone: widget.onSubmitted,
      ),
    ).whenComplete(() {
      // The sheet is its own FocusScope — hand focus back to the shell so the
      // remote can immediately navigate away (e.g. down into search results).
      if (mounted) _shell.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = _shell.hasPrimaryFocus;
    return Focus(
      focusNode: _shell,
      onKeyEvent: _onShellKey,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: highlighted ? AppTheme.focus : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: widget.builder(context, _field),
      ),
    );
  }
}
