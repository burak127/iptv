import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'pairing_models.dart';

/// A tiny local web server: the TV serves a form page on the LAN, the phone
/// opens it (via QR/URL), fills in M3U/Xtream and submits — the fields come
/// back through [onSubmit], which returns true only if a source was saved.
/// Everything stays on the local network.
class PairingServer {
  static bool get supported => true;

  static const int _maxBody = 64 * 1024; // plenty for an M3U URL / Xtream creds

  HttpServer? _server;
  bool _stopped = false;

  /// Unguessable path segment that gates every request. It rides in the QR URL
  /// only, so a blind LAN peer OR a malicious cross-origin page (which can send
  /// a form POST but can't know this token) hits 404 instead of injecting a
  /// source. Without it, any device on the Wi-Fi could replace the active
  /// playlist.
  static String _newToken() {
    final r = Random.secure();
    return List<int>.generate(8, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<PairingInfo?> start(
      Future<bool> Function(Map<String, String> fields) onSubmit) async {
    _stopped = false;
    final ip = await _lanIp();
    if (ip == null) return null;

    // Bind WITHOUT shared:true — a stale/leaked listener on the same port must
    // fail loudly into the port-0 fallback, never silently split traffic with a
    // zombie server whose onSubmit closure is dead.
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0); // any free port
    }
    // The screen may have been popped while bind() was in flight — stop() ran
    // before _server was set (a no-op), so close here or we leak an open,
    // unauthenticated listener for the process lifetime.
    if (_stopped) {
      await server.close(force: true);
      return null;
    }
    _server = server;
    final token = _newToken();
    final port = server.port;
    final path = '/$token';

    server.listen((HttpRequest req) async {
      try {
        // Every request must carry the secret path; anything else is 404.
        if (req.uri.path != path) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        if (req.method != 'POST') {
          await _reply(req, _formHtml(token));
          return;
        }
        // Only genuine form posts (blocks stray cross-origin JSON/etc.).
        final ct = req.headers.contentType;
        if (ct == null || ct.mimeType != 'application/x-www-form-urlencoded') {
          req.response.statusCode = HttpStatus.unsupportedMediaType;
          await req.response.close();
          return;
        }
        // Cap the body so a rogue LAN peer can't exhaust memory.
        if (req.contentLength > _maxBody) {
          req.response.statusCode = HttpStatus.requestEntityTooLarge;
          await req.response.close();
          return;
        }
        final buf = <int>[];
        await for (final chunk in req) {
          buf.addAll(chunk);
          if (buf.length > _maxBody) {
            req.response.statusCode = HttpStatus.requestEntityTooLarge;
            await req.response.close();
            return;
          }
        }
        final fields = Uri.splitQueryString(utf8.decode(buf, allowMalformed: true));
        final ok = await onSubmit(fields);
        await _reply(req, ok ? _successHtml() : _errorHtml(token),
            status: ok ? 200 : 400);
        // Single-shot: once a source is accepted, close the server so the
        // LAN exposure window is as small as possible.
        if (ok) await stop();
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });

    return PairingInfo('http://$ip:$port$path', ip, port);
  }

  Future<void> stop() async {
    _stopped = true;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _reply(HttpRequest req, String html, {int status = 200}) async {
    try {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..write(html);
      await req.response.close();
    } catch (_) {
      // Client disconnected mid-request — nothing to do.
    }
  }

  /// Best real LAN IPv4: prefer physical adapters (skip Hyper-V/WSL/VPN/Docker
  /// virtual ones and link-local), and prefer 192.168 > 10 > 172.16-31.
  Future<String?> _lanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      const virtualHints = [
        'vethernet', 'wsl', 'hyper-v', 'virtualbox', 'vmware',
        'docker', 'loopback', 'tailscale', 'zerotier', 'tap', 'tun',
        // Cellular interfaces carry a CGNAT 10.x address no LAN peer can
        // reach — a QR pointing there would never work.
        'rmnet', 'ccmni', 'pdp_ip', 'clat',
      ];
      final candidates = <String>[];
      final fallback = <String>[];
      for (final i in ifaces) {
        final name = i.name.toLowerCase();
        final isVirtual = virtualHints.any(name.contains);
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('169.254.')) continue; // link-local
          if (isVirtual) continue; // never even as fallback
          fallback.add(ip);
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            candidates.add(ip);
          }
        }
      }
      candidates.sort((a, b) {
        int rank(String ip) => ip.startsWith('192.168.')
            ? 0
            : ip.startsWith('10.')
                ? 1
                : 2; // 172.16-31
        return rank(a).compareTo(rank(b));
      });
      if (candidates.isNotEmpty) return candidates.first;
      if (fallback.isNotEmpty) return fallback.first;
    } catch (_) {}
    return null;
  }

  bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  String _formHtml(String token) => '''
<!DOCTYPE html><html lang="da"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tilføj IPTV-kilde</title>
<style>
body{font-family:-apple-system,system-ui,sans-serif;background:#0E1116;color:#fff;margin:0;padding:20px;}
.card{max-width:460px;margin:0 auto;}
h1{font-size:20px;margin:0 0 4px;}
p.sub{color:#8b93a5;margin:0 0 16px;}
label{display:block;margin:14px 0 6px;color:#aab;font-size:14px;}
input{width:100%;box-sizing:border-box;padding:13px;border-radius:10px;border:1px solid #2a3342;background:#1b2230;color:#fff;font-size:16px;}
.tabs{display:flex;gap:8px;margin:14px 0 4px;}
.tab{flex:1;padding:12px;text-align:center;border-radius:10px;background:#1b2230;cursor:pointer;user-select:none;}
.tab.active{background:#3E7BFA;}
button{width:100%;margin-top:22px;padding:15px;border:none;border-radius:10px;background:#3E7BFA;color:#fff;font-size:17px;font-weight:600;}
.hidden{display:none;}
</style></head><body><div class="card">
<h1>Tilføj IPTV-kilde</h1>
<p class="sub">Udfyld og send til dit TV.</p>
<form method="POST" action="/$token">
<div class="tabs">
<div class="tab active" id="tabM3u" onclick="sel('m3u')">M3U-playliste</div>
<div class="tab" id="tabX" onclick="sel('xtream')">Xtream Codes</div>
</div>
<input type="hidden" name="type" id="type" value="m3u">
<label>Navn (valgfrit)</label><input name="name" placeholder="Min udbyder">
<div id="m3uFields">
<label>M3U URL</label><input name="m3uUrl" inputmode="url" placeholder="http://.../get.php?...">
</div>
<div id="xFields" class="hidden">
<label>Server (host)</label><input name="host" inputmode="url" placeholder="http://server:8080">
<label>Brugernavn</label><input name="username" autocapitalize="none" autocomplete="off">
<label>Adgangskode</label><input name="password" autocapitalize="none" autocomplete="off">
</div>
<button type="submit">Send til TV</button>
</form></div>
<script>
function sel(t){document.getElementById('type').value=t;
document.getElementById('tabM3u').classList.toggle('active',t=='m3u');
document.getElementById('tabX').classList.toggle('active',t=='xtream');
document.getElementById('m3uFields').classList.toggle('hidden',t!='m3u');
document.getElementById('xFields').classList.toggle('hidden',t!='xtream');}
</script></body></html>''';

  String _successHtml() => '''
<!DOCTYPE html><html lang="da"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sendt</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0E1116;color:#fff;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;}</style>
</head><body><div><div style="font-size:64px">&#9989;</div>
<h1>Sendt til TV!</h1><p style="color:#8b93a5">Du kan lukke denne side.</p></div></body></html>''';

  String _errorHtml(String token) => '''
<!DOCTYPE html><html lang="da"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Udfyld feltet</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0E1116;color:#fff;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center;padding:24px;}
a{color:#3E7BFA;}</style>
</head><body><div><div style="font-size:64px">&#10060;</div>
<h1>Ikke gemt</h1><p style="color:#8b93a5">Udfyld M3U URL eller server og prøv igen.</p>
<p><a href="/$token">Tilbage</a></p></div></body></html>''';
}
