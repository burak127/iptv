import 'dart:io';

/// IPTV providers routinely serve HTTPS with self-signed or expired
/// certificates. Every mainstream IPTV player tolerates that — otherwise the
/// playlist/API simply "won't download". This installs a global HttpOverrides
/// that accepts bad certificates for API/playlist/logo requests.
///
/// Trade-off, made deliberately: the payloads are public TV catalogs, not
/// credentials-bearing web logins, and the alternative is a broken app on a
/// large share of real providers.
class TlsOverrides {
  static void install() {
    HttpOverrides.global = _PermissiveHttpOverrides();
  }
}

class _PermissiveHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (cert, host, port) => true;
  }
}
