import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/tv_mode.dart';
import '../../theme.dart';

/// A tappable container that shows a clear highlight when focused — the core
/// D-pad building block. Reports focus changes so callers can remember the last
/// focused item per pane. When [onLongPress] is set, holding OK on a remote
/// (or long-pressing on touch) triggers it — used for favorite toggling.
class FocusableCard extends StatefulWidget {
  const FocusableCard({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.borderRadius = 14,
    this.padding = EdgeInsets.zero,
    this.focusNode,
    this.onFocusChange,
    this.scaleOnFocus = true,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final double borderRadius;
  final EdgeInsets padding;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final bool scaleOnFocus;

  @override
  State<FocusableCard> createState() => _FocusableCardState();
}

class _FocusableCardState extends State<FocusableCard> {
  bool _focused = false;
  bool _longFired = false;

  void _setFocus(bool v) {
    if (v == _focused) return;
    setState(() => _focused = v);
    widget.onFocusChange?.call(v);
  }

  /// With onLongPress set we take over select/enter handling: key-repeat
  /// (holding OK) fires the long-press; a plain press fires onTap on key-up.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.onLongPress == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isSelect = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!isSelect) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _longFired = false;
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      if (!_longFired) {
        _longFired = true;
        widget.onLongPress!.call();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (!_longFired) widget.onTap();
      _longFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // The outer non-focusable Focus intercepts select/enter down/repeat/up
    // (bubbling from the focused detector) to implement hold-OK-for-favorite.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onShowFocusHighlight: _setFocus,
      onFocusChange: _setFocus,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: (_focused && widget.scaleOnFocus) ? AppTheme.focusedScale : 1.0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: _focused ? AppTheme.focus : Colors.transparent,
                width: AppTheme.focusRingWidth,
              ),
              // The blurred glow is GPU-expensive to animate on every focus move.
              // On TV the 4px accent border + scale already mark focus clearly,
              // so skip the shadow there to keep grid navigation smooth.
              boxShadow: _focused && !isTvMode
                  ? [
                      BoxShadow(
                        color: AppTheme.focus.withValues(alpha: 0.35),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
      ),
    );
  }
}
