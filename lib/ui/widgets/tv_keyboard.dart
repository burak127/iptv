import 'package:flutter/material.dart';

import '../../theme.dart';
import 'focus_ring.dart';

/// A fully in-Flutter on-screen keyboard for D-pad remotes.
///
/// Android TV's SYSTEM soft keyboard has long-standing, unresolved D-pad
/// navigation bugs on real hardware (flutter/flutter#125541, #147772) — once
/// a TextField grabs it, the remote can move focus onto the keyboard but
/// often can't move BETWEEN its own keys or activate one. That's an engine/
/// platform-IME limitation, not something fixable from application code.
/// TiviMate, Netflix, YouTube etc. all sidestep it the same way: render their
/// own keyboard entirely inside the app, driven by the SAME FocusRing/D-pad
/// machinery already used everywhere else in this UI, so it's guaranteed
/// reachable and navigable regardless of the box/ROM's IME quirks.
class TvKeyboard extends StatefulWidget {
  const TvKeyboard({super.key, required this.controller, this.onDone});

  final TextEditingController controller;
  final VoidCallback? onDone;

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  static const _rows = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm', '-', '.'],
  ];

  void _insert(String ch) {
    final v = widget.controller.value;
    final text = v.text;
    final sel = v.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(start, end, ch),
      selection: TextSelection.collapsed(offset: start + ch.length),
    );
  }

  void _backspace() {
    final v = widget.controller.value;
    final text = v.text;
    final sel = v.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    if (start != end) {
      widget.controller.value = TextEditingValue(
        text: text.replaceRange(start, end, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    } else if (start > 0) {
      widget.controller.value = TextEditingValue(
        text: text.replaceRange(start - 1, start, ''),
        selection: TextSelection.collapsed(offset: start - 1),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Live preview of the current text, since the underlying field
              // may be scrolled off-screen behind this panel.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, v, _) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      v.text.isEmpty ? ' ' : v.text,
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < _rows.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final ch in _rows[i])
                        _key(ch, () => _insert(ch), autofocus: i == 0 && ch == '1'),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _wideKey('MELLEMRUM', () => _insert(' ')),
                    _key('', _backspace, icon: Icons.backspace_outlined),
                    _wideKey('FÆRDIG', () {
                      widget.onDone?.call();
                      Navigator.of(context).maybePop();
                    }, isPrimary: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(String label, VoidCallback onTap,
      {IconData? icon, bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: FocusRing(
        borderRadius: 8,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Material(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              autofocus: autofocus,
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 18, color: Colors.white)
                    : Text(label,
                        style: const TextStyle(
                            fontSize: 15,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wideKey(String label, VoidCallback onTap, {bool isPrimary = false}) {
    return Padding(
      padding: const EdgeInsets.all(3),
      child: FocusRing(
        borderRadius: 8,
        child: SizedBox(
          height: 42,
          child: Material(
            color: isPrimary ? AppTheme.seed : AppTheme.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
