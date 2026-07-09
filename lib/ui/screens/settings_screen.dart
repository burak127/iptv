import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/iptv_source.dart';
import '../../services/download_manager.dart';
import '../../services/pip_service.dart';
import '../../services/tv_mode.dart';
import '../widgets/tv_text_field.dart';
import '../widgets/focus_ring.dart';
import '../../services/xtream_client.dart';
import '../../state/app_state.dart';
import 'sources_screen.dart';

/// App-wide settings: source management, stream-format preference, parental PIN,
/// cache, Xtream account info and an about entry.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Memoized so FutureBuilder doesn't re-fire (network auth / prefs read) on
  // every AppState.notifyListeners() rebuild.
  late Future<bool> _hasPinFuture;
  late Future<XtreamUserInfo?> _accountFuture;

  // Android 14's separate full-screen-intent gate (see MainActivity.kt) —
  // only relevant/shown once "Start automatisk" is actually on, so this is
  // an optimistic default until checked, not a false alarm on other Android
  // versions where it's simply not applicable.
  bool _fullScreenIntentOk = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>();
    _hasPinFuture = s.progress.hasPin();
    _accountFuture = s.accountInfo();
    if (isTvMode) _refreshFullScreenIntentCheck();
  }

  void _refreshFullScreenIntentCheck() {
    PipService.canUseFullScreenIntent().then((ok) {
      if (mounted) setState(() => _fullScreenIntentOk = ok);
    });
  }

  void _refreshPin() {
    setState(() => _hasPinFuture = context.read<AppState>().progress.hasPin());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = state.active;

    return Scaffold(
      appBar: AppBar(title: const Text('Indstillinger')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _SectionHeader('Kilder'),
          FocusRing(
            borderRadius: 10,
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Kilder'),
              subtitle: Text(active?.name ?? 'Ingen kilde valgt'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SourcesScreen()),
              ),
            ),
          ),
          if (active != null) ...[
            const _SectionHeader('Stream-format'),
            FocusRing(
              borderRadius: 10,
              child: ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('Stream-format'),
                subtitle: Text(_formatLabel(active.streamFormat)),
                trailing: const Icon(Icons.tune),
                onTap: () => _pickStreamFormat(active),
              ),
            ),
          ],
          if (isTvMode) ...[
            const _SectionHeader('Video'),
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: const Icon(Icons.tv),
                title: const Text('Native afspiller (glat på TV-bokse)'),
                subtitle: const Text(
                  'Bruger ExoPlayer + hardware-overlay til live-TV — samme metode '
                  'som TiviMate. Fjerner hakket på svage bokse. Kun live-TV; '
                  'genåbn kanalen efter ændring.',
                ),
                value: nativePlayer,
                onChanged: (v) async {
                  await setNativePlayer(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: const Icon(Icons.hd_outlined),
                title: const Text('Glat hardware-video (media_kit)'),
                subtitle: const Text(
                  'Alternativ til den native afspiller. Giver sort skærm (kun lyd) '
                  'på nogle bokse — slå fra igen hvis det sker. Genåbn kanalen '
                  'efter ændring.',
                ),
                value: directHwVideo,
                onChanged: (v) async {
                  await setDirectHwVideo(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
          if (isTvMode) ...[
            const _SectionHeader('Opstart'),
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: const Icon(Icons.power_settings_new),
                title: const Text('Start automatisk når boksen tændes'),
                subtitle: const Text(
                  'Åbner appen af sig selv efter opstart — nemt for '
                  'bedsteforældre. (Virker på de fleste TV-bokse.)',
                ),
                value: autoStartOnBoot,
                onChanged: (v) async {
                  await setAutoStartOnBoot(v);
                  if (mounted) setState(() {});
                  _refreshFullScreenIntentCheck();
                },
              ),
            ),
            // Android 14 gates the full-screen-intent notification
            // (BootReceiver's fallback when the OS blocks a background
            // receiver from starting an activity directly — see
            // MainActivity.kt) behind a SEPARATE permission a background
            // receiver can't request itself. Only shown when it's actually
            // needed: feature on, and the platform reports it's missing.
            if (autoStartOnBoot && !_fullScreenIntentOk)
              FocusRing(
                borderRadius: 10,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.warning_amber, color: Colors.amber),
                  title: const Text('Kræver en ekstra tilladelse'),
                  subtitle: const Text(
                    'Android 14 skal have lov manuelt, før "Start automatisk" '
                    'virker på denne boks. Tryk her for at åbne indstillingen.',
                  ),
                  onTap: () async {
                    await PipService.openFullScreenIntentSettings();
                    _refreshFullScreenIntentCheck();
                  },
                ),
              ),
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: const Icon(Icons.play_circle_outline),
                title: const Text('Fortsæt på sidste kanal'),
                subtitle: const Text(
                  'Åbner automatisk den kanal der sidst blev set, når appen '
                  'starter — i stedet for kanallisten.',
                ),
                value: resumeLastChannel,
                onChanged: (v) async {
                  await setResumeLastChannel(v);
                  if (mounted) setState(() {});
                },
              ),
            ),
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: const Icon(Icons.home_outlined),
                title: const Text('Gør til startskærm'),
                subtitle: const Text(
                  'Boksen åbner altid appen ved tryk på HOME/opstart — den '
                  'sikreste bedsteforælder-opsætning. Slå fra igen for at få '
                  'boksens normale startskærm tilbage.',
                ),
                value: homeReplacement,
                onChanged: (v) async {
                  final messenger = ScaffoldMessenger.of(context);
                  final applied = await setHomeReplacement(v);
                  if (!mounted) return;
                  setState(() {});
                  if (!applied) {
                    messenger.showSnackBar(const SnackBar(
                      content: Text(
                          'Kan ikke slås fra: boksen har ingen anden aktiv '
                          'startskærm, så det ville give en sort skærm.'),
                    ));
                  }
                },
              ),
            ),
          ],
          const _SectionHeader('Forældre-PIN'),
          FutureBuilder<bool>(
            future: _hasPinFuture,
            builder: (context, snap) {
              final hasPin = snap.data ?? false;
              return FocusRing(
                borderRadius: 10,
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(hasPin ? 'Fjern PIN' : 'Opret PIN'),
                  subtitle: Text(
                    hasPin
                        ? 'Skjuler voksenindhold (XXX/Adult/+18) indtil PIN indtastes'
                        : 'Ingen PIN oprettet',
                  ),
                  trailing: Icon(hasPin ? Icons.lock_open : Icons.add),
                  onTap: () => _handlePin(hasPin),
                ),
              );
            },
          ),
          if (state.hasParentalPin)
            FocusRing(
              borderRadius: 10,
              child: SwitchListTile(
                secondary: Icon(
                    state.adultLocked ? Icons.visibility_off : Icons.visibility),
                title: const Text('Vis voksenindhold'),
                subtitle: Text(state.adultLocked
                    ? 'Låst — slå til med PIN for denne session'
                    : 'Vises indtil appen genstartes'),
                value: !state.adultLocked,
                onChanged: (want) => _toggleAdult(state, want),
              ),
            ),
          const _SectionHeader('Data'),
          FocusRing(
            borderRadius: 10,
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Ryd cache'),
              subtitle: const Text('Sletter mellemlagrede lister'),
              trailing: const Icon(Icons.delete_sweep_outlined),
              onTap: _clearCache,
            ),
          ),
          FocusRing(
            borderRadius: 10,
            child: ListTile(
              leading: const Icon(Icons.upload_outlined),
              title: const Text('Eksportér opsætning'),
              subtitle: const Text('Kopierer kilder, favoritter og rækkefølge til udklipsholderen'),
              onTap: _exportBackup,
            ),
          ),
          FocusRing(
            borderRadius: 10,
            child: ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Importér opsætning'),
              subtitle: const Text('Indsætter en backup fra udklipsholderen'),
              onTap: _importBackup,
            ),
          ),
          Consumer<DownloadManager>(
            builder: (context, dm, _) {
              if (!dm.supported) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SectionHeader('Downloads'),
                  FocusRing(
                    borderRadius: 10,
                    child: SwitchListTile(
                      secondary: const Icon(Icons.photo_library_outlined),
                      title: const Text('Gem downloads i galleriet'),
                      subtitle: const Text(
                        'Hentede film/serier vises også i Videoer/Filer',
                      ),
                      value: dm.saveToGallery,
                      onChanged: dm.setSaveToGallery,
                    ),
                  ),
                ],
              );
            },
          ),
          if (state.activeIsXtream) ...[
            const _SectionHeader('Konto'),
            FutureBuilder<XtreamUserInfo?>(
              future: _accountFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const ListTile(
                    leading: Icon(Icons.person_outline),
                    title: Text('Konto'),
                    subtitle: Text('Henter kontooplysninger …'),
                    trailing: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final info = snap.data;
                if (info == null) {
                  return const ListTile(
                    leading: Icon(Icons.person_off_outlined),
                    title: Text('Konto'),
                    subtitle: Text('Kunne ikke hente kontooplysninger'),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _InfoTile(
                      icon: Icons.verified_user_outlined,
                      label: 'Status',
                      value: info.status.isEmpty ? '—' : info.status,
                    ),
                    _InfoTile(
                      icon: Icons.dns_outlined,
                      label: 'Maks. forbindelser',
                      value: '${info.maxConnections}',
                    ),
                    _InfoTile(
                      icon: Icons.cast_connected_outlined,
                      label: 'Aktive forbindelser',
                      value: '${info.activeConnections}',
                    ),
                    _InfoTile(
                      icon: Icons.event_outlined,
                      label: 'Udløber',
                      value: _formatDate(info.expiry),
                    ),
                  ],
                );
              },
            ),
          ],
          const _SectionHeader('Om'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('IPTV Player · v0.2'),
          ),
        ],
      ),
    );
  }

  static String _formatLabel(StreamFormat f) {
    switch (f) {
      case StreamFormat.auto:
        return 'Automatisk';
      case StreamFormat.ts:
        return 'MPEG-TS (.ts)';
      case StreamFormat.hls:
        return 'HLS (.m3u8)';
    }
  }

  Future<void> _pickStreamFormat(IptvSource active) async {
    final chosen = await showDialog<StreamFormat>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('Vælg stream-format'),
          children: [
            for (final f in StreamFormat.values)
              FocusRing(
                borderRadius: 10,
                child: ListTile(
                  // Open with the current choice focused so the first OK press
                  // on a remote isn't dead.
                  autofocus: f == active.streamFormat,
                  title: Text(_formatLabel(f)),
                  trailing:
                      f == active.streamFormat ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(context).pop(f),
                ),
              ),
          ],
        );
      },
    );
    if (chosen == null || chosen == active.streamFormat) return;
    if (!mounted) return;
    await context.read<AppState>().updateSource(active.copyWith(streamFormat: chosen));
  }

  Future<void> _handlePin(bool hasPin) async {
    final state = context.read<AppState>();
    if (hasPin) {
      // Require the current PIN before removing it — otherwise anyone with the
      // remote could disable the parental gate in two clicks.
      final entered = await _promptPin(title: 'Indtast PIN for at fjerne');
      if (entered == null) return;
      if (!await state.progress.checkPin(entered)) {
        if (mounted) _snack('Forkert PIN');
        return;
      }
      await state.progress.clearPin();
      await state.refreshParentalPin();
      if (!mounted) return;
      _snack('PIN fjernet');
      _refreshPin();
      return;
    }
    final pin = await _promptPin();
    if (pin == null) return;
    await state.progress.setPin(pin);
    await state.refreshParentalPin();
    if (!mounted) return;
    _snack('PIN oprettet — voksenindhold er nu skjult');
    _refreshPin();
  }

  Future<void> _toggleAdult(AppState state, bool wantVisible) async {
    if (!wantVisible) {
      state.lockAdult();
      return;
    }
    final entered = await _promptPin(title: 'Indtast PIN');
    if (entered == null) return;
    final ok = await state.unlockAdult(entered);
    if (mounted && !ok) _snack('Forkert PIN');
  }

  Future<String?> _promptPin({String title = 'Opret PIN'}) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) {
          String? error;
          return StatefulBuilder(
            builder: (context, setLocal) {
              return AlertDialog(
                title: Text(title),
                // DpadEscape: Down must reach the dialog buttons instead of
                // being eaten by the field's caret movement on TV.
                content: DpadEscape(
                    child: TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 4,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: InputDecoration(
                    labelText: '4-cifret PIN',
                    counterText: '',
                    errorText: error,
                  ),
                  onSubmitted: (_) => _submitPin(context, controller, setLocal, (e) => error = e),
                )),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuller'),
                  ),
                  FilledButton(
                    onPressed: () => _submitPin(context, controller, setLocal, (e) => error = e),
                    child: const Text('Gem'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  void _submitPin(
    BuildContext context,
    TextEditingController controller,
    void Function(void Function()) setLocal,
    void Function(String?) setError,
  ) {
    final value = controller.text.trim();
    if (value.length != 4) {
      setLocal(() => setError('PIN skal være 4 cifre'));
      return;
    }
    Navigator.of(context).pop(value);
  }

  Future<void> _clearCache() async {
    await context.read<AppState>().clearCache();
    if (!mounted) return;
    _snack('Cache ryddet');
  }

  Future<void> _exportBackup() async {
    final json = await context.read<AppState>().exportBackup();
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _snack('Opsætning kopieret — indsæt den i "Importér" på den anden enhed.');
  }

  Future<void> _importBackup() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text;
    if (raw == null || raw.trim().isEmpty) {
      if (mounted) _snack('Udklipsholderen er tom.');
      return;
    }
    if (!mounted) return;
    try {
      final added = await context.read<AppState>().importBackup(raw.trim());
      if (!mounted) return;
      _snack(added > 0
          ? 'Importeret: $added ny${added == 1 ? '' : 'e'} kilde${added == 1 ? '' : 'r'}.'
          : 'Backup importeret (ingen nye kilder).');
    } catch (e) {
      if (mounted) _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  static String _formatDate(DateTime? d) {
    if (d == null) return '—';
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(label),
      trailing: Text(value, style: const TextStyle(color: Colors.white70)),
    );
  }
}
