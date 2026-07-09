import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/iptv_source.dart';
import '../../services/pairing_server.dart';
import '../../state/app_state.dart';
import '../widgets/focus_ring.dart';

/// Shows a QR code + LAN URL. The user opens it on their phone (same WiFi),
/// fills in M3U/Xtream in the browser and submits — the source lands on the TV.
class AddFromPhoneScreen extends StatefulWidget {
  const AddFromPhoneScreen({super.key});

  @override
  State<AddFromPhoneScreen> createState() => _AddFromPhoneScreenState();
}

class _AddFromPhoneScreenState extends State<AddFromPhoneScreen> {
  final _server = PairingServer();
  PairingInfo? _info;
  bool _starting = true;
  bool _received = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final info = await _server.start(_onSubmit);
      if (!mounted) {
        // Backed out while the server was still binding — don't leak the
        // now-running (unauthenticated) listener.
        unawaited(_server.stop());
        return;
      }
      setState(() {
        _info = info;
        _starting = false;
        if (info == null) {
          _error =
              'Kunne ikke finde et netværk. Forbind TV\'et til samme WiFi som telefonen.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'Kunne ikke starte den lokale server.';
      });
    }
  }

  /// Returns true only if a source was actually accepted, so the phone gets a
  /// real success page (not a false one on an empty/duplicate submit).
  Future<bool> _onSubmit(Map<String, String> f) async {
    if (!mounted || _received) return false;
    final type = f['type'] ?? 'm3u';
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final name = (f['name'] ?? '').trim();

    IptvSource source;
    if (type == 'xtream') {
      final host = (f['host'] ?? '').trim();
      if (host.isEmpty) return false;
      source = IptvSource.xtream(
        id: id,
        name: name.isEmpty ? 'Xtream' : name,
        host: host,
        username: (f['username'] ?? '').trim(),
        password: (f['password'] ?? '').trim(),
      );
    } else {
      var url = (f['m3uUrl'] ?? '').trim();
      if (url.isEmpty) return false;
      // Tolerate scheme-less URLs pasted from the phone.
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'http://$url';
      }
      // An M3U link with embedded Xtream credentials becomes an Xtream source
      // (survives get.php blocks + unlocks Film/Serier/Guide).
      source = IptvSource.xtreamFromM3uUrl(
              id: id, name: name.isEmpty ? 'Xtream-konto' : name, url: url) ??
          IptvSource.m3u(id: id, name: name.isEmpty ? 'M3U' : name, url: url);
    }

    // Don't block the phone's HTTP response on the (possibly slow) channel load,
    // but catch a persistence failure so it can't become an unhandled error.
    // A bad URL isn't an error here — it surfaces on the Live screen after load.
    unawaited(context.read<AppState>().addSource(source).catchError((Object _) {
      if (mounted) setState(() => _error = 'Kunne ikke gemme kilden.');
    }));
    setState(() => _received = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    });
    return true;
  }

  @override
  void dispose() {
    _server.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tilføj fra telefon')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _content(),
        ),
      ),
    );
  }

  Widget _content() {
    if (_starting) return const CircularProgressIndicator();
    if (_received) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: Colors.greenAccent, size: 72),
          SizedBox(height: 16),
          Text('Kilde modtaget!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        ],
      );
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, color: Colors.redAccent, size: 56),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
        ],
      );
    }

    final info = _info!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Skriv fra din telefon',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Slipper for at taste på fjernbetjeningen.',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: info.url,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          const _Step(1, 'Forbind telefonen til samme WiFi som TV\'et'),
          const _Step(2, 'Scan QR-koden — eller åbn adressen herunder i telefonens browser'),
          const _Step(3, 'Udfyld M3U eller Xtream og tryk “Send til TV”'),
          const SizedBox(height: 16),
          FocusRing(
            borderRadius: 8,
            child: SelectableText(
              info.url,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Text('$number', style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
