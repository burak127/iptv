import 'package:flutter/material.dart';

import '../../services/tv_mode.dart';
import '../../theme.dart';

/// Draws a strong accent ring + glow around [child] whenever the child (or any
/// of its descendants) holds focus — so a D-pad cursor is unmistakable on TV,
/// and always reads ABOVE a competing "selected" tint.
///
/// It does NOT add a focus stop of its own (canRequestFocus:false,
/// skipTraversal:true); it merely observes descendant focus. Wrap any already-
/// focusable row (ListTile, ChoiceChip, SwitchListTile, a Card of IconButtons,
/// a Slider …) with it.
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.child,
    this.borderRadius = 12,
    this.shape = BoxShape.rectangle,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double borderRadius;
  final BoxShape shape;
  final EdgeInsetsGeometry padding;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

/// Pill button with dead-centered icon+label (the default OutlinedButton line
/// height makes text ride visibly off-center in compact boxes on TV).
class TvPillButton extends StatelessWidget {
  const TvPillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        alignment: Alignment.center,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: AppTheme.tvFont(13.5, 15),
              fontWeight: FontWeight.w600,
              height: 1.0, // kill the line-height offset — glyphs sit centered
            ),
          ),
        ],
      ),
    );
  }
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isCircle = widget.shape == BoxShape.circle;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: widget.padding,
        decoration: BoxDecoration(
          shape: widget.shape,
          borderRadius:
              isCircle ? null : BorderRadius.circular(widget.borderRadius),
          // Constant width (transparent when idle) so there's no layout jump.
          border: Border.all(
            color: _focused ? AppTheme.focus : Colors.transparent,
            width: AppTheme.focusRingWidth,
          ),
          color: _focused ? AppTheme.focus.withValues(alpha: 0.16) : null,
          // Skip the animated blur glow on TV — the border + fill already mark
          // focus, and blurred shadows are costly to animate on weak TV GPUs.
          boxShadow: _focused && !isTvMode
              ? [
                  BoxShadow(
                    color: AppTheme.focus.withValues(alpha: 0.35),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}
