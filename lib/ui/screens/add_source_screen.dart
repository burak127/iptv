import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/iptv_source.dart';
import '../../services/pairing_server.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';
import 'add_from_phone_screen.dart';

/// Form for adding a new IPTV source — either an M3U playlist or an
/// Xtream Codes account. Works with both touch and a D-pad remote.
///
/// When [isFirstRun] is true the screen never pops on success; the root widget
/// swaps to the main shell automatically once a source becomes active.
/// [startInXtreamMode] pre-selects the Xtream segment (used by the onboarding
/// flow where Xtream is the recommended path).
class AddSourceScreen extends StatefulWidget {
  const AddSourceScreen({
    super.key,
    this.isFirstRun = false,
    this.startInXtreamMode = false,
  });

  final bool isFirstRun;
  final bool startInXtreamMode;

  @override
  State<AddSourceScreen> createState() => _AddSourceScreenState();
}

class _AddSourceScreenState extends State<AddSourceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  late SourceType _type =
      widget.startInXtreamMode ? SourceType.xtream : SourceType.m3u;
  bool _obscurePassword = true;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _hostCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// Adds the missing `http://` when the user typed a scheme-less URL
  /// ("server.com/get.php?…") — a very common way playlists get shared.
  static String _normalizeUrl(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return v;
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    return 'http://$v';
  }

  String? _validateUrl(String? value) {
    final raw = _normalizeUrl(value ?? '');
    if (raw.isEmpty) return 'Indtast en M3U URL';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      return 'Ugyldig URL';
    }
    return null;
  }

  String? _validateRequired(String? value, String label) {
    if ((value?.trim() ?? '').isEmpty) return 'Indtast $label';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final name = _nameCtrl.text.trim();

    final IptvSource source;
    if (_type == SourceType.m3u) {
      final url = _normalizeUrl(_urlCtrl.text);
      // An M3U link with embedded Xtream credentials is served via the API
      // instead — same provider/login, but it also survives get.php blocks
      // and unlocks Film/Serier/Guide.
      final converted = IptvSource.xtreamFromM3uUrl(
        id: id,
        name: name.isEmpty ? 'Xtream-konto' : name,
        url: url,
      );
      if (converted != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Linket indeholder et Xtream-login — tilføjet som Xtream Codes '
              '(giver også Film, Serier og Guide).'),
        ));
      }
      source = converted ??
          IptvSource.m3u(
            id: id,
            name: name.isEmpty ? 'M3U-playlist' : name,
            url: url,
          );
    } else {
      source = IptvSource.xtream(
        id: id,
        name: name.isEmpty ? 'Xtream-konto' : name,
        host: _hostCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
    }

    final state = context.read<AppState>();
    await state.addSource(source);
    if (!mounted) return;

    if (state.liveError != null) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.liveError!)),
      );
      return;
    }

    if (!widget.isFirstRun) {
      Navigator.of(context).pop();
    }
    // On first run we intentionally do not pop: the root widget swaps to the
    // main shell once a source is active.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isFirstRun ? 'Kom i gang' : 'Tilføj kilde'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: DpadEscape(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (PairingServer.supported) ...[
                    OutlinedButton.icon(
                      autofocus: true,
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const AddFromPhoneScreen()),
                              ),
                      icon: const Icon(Icons.smartphone),
                      label: const Text('Skriv fra telefonen i stedet'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('eller', style: TextStyle(color: Colors.white54)),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  // Two plain focusable buttons instead of SegmentedButton —
                  // segments have a near-invisible focus state on TV, making
                  // the type switch effectively dead with a D-pad remote.
                  Row(
                    children: [
                      Expanded(
                        child: _TypeButton(
                          label: 'M3U',
                          icon: Icons.link,
                          selected: _type == SourceType.m3u,
                          onTap: _saving
                              ? () {}
                              : () => setState(() => _type = SourceType.m3u),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _TypeButton(
                          label: 'Xtream Codes',
                          icon: Icons.dns,
                          selected: _type == SourceType.xtream,
                          onTap: _saving
                              ? () {}
                              : () => setState(() => _type = SourceType.xtream),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TvTextInput(
                    controller: _nameCtrl,
                    builder: (context, node) => TextFormField(
                      controller: _nameCtrl,
                      focusNode: node,
                      textInputAction: TextInputAction.next,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Navn (valgfrit)',
                        prefixIcon: Icon(Icons.label_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_type == SourceType.m3u)
                    TvTextInput(
                      controller: _urlCtrl,
                      builder: (context, node) => TextFormField(
                        controller: _urlCtrl,
                        focusNode: node,
                        enabled: !_saving,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        validator: _validateUrl,
                        decoration: const InputDecoration(
                          labelText: 'M3U URL',
                          hintText: 'http://…/get.php?…',
                          prefixIcon: Icon(Icons.playlist_play),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    )
                  else ...[
                    TvTextInput(
                      controller: _hostCtrl,
                      builder: (context, node) => TextFormField(
                        controller: _hostCtrl,
                        focusNode: node,
                        enabled: !_saving,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        validator: (v) => _validateRequired(v, 'server'),
                        decoration: const InputDecoration(
                          labelText: 'Server',
                          hintText: 'http://example.com:8080',
                          prefixIcon: Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TvTextInput(
                      controller: _userCtrl,
                      builder: (context, node) => TextFormField(
                        controller: _userCtrl,
                        focusNode: node,
                        enabled: !_saving,
                        textInputAction: TextInputAction.next,
                        validator: (v) => _validateRequired(v, 'brugernavn'),
                        decoration: const InputDecoration(
                          labelText: 'Brugernavn',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TvTextInput(
                      controller: _passCtrl,
                      builder: (context, node) => TextFormField(
                        controller: _passCtrl,
                        focusNode: node,
                        enabled: !_saving,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        validator: (v) => _validateRequired(v, 'adgangskode'),
                        decoration: InputDecoration(
                          labelText: 'Adgangskode',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword
                                ? 'Vis adgangskode'
                                : 'Skjul adgangskode',
                            icon: Icon(_obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: _saving
                                ? null
                                : () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: Text(_saving ? 'Forbinder…' : 'Gem og forbind'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large, D-pad-friendly source-type button with an unmistakable selected
/// state (accent fill) and the app's standard focus ring.
class _TypeButton extends StatelessWidget {
  const _TypeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.focus : Colors.white70;
    return FocusableCard(
      onTap: onTap,
      scaleOnFocus: false,
      borderRadius: 12,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.seed.withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? Icons.check : icon, size: 20, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.tvFont(14, 16),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
