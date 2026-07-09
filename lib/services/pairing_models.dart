/// Info about the running local pairing server so the UI can show a QR + URL.
class PairingInfo {
  final String url; // http://ip:port/
  final String host;
  final int port;
  const PairingInfo(this.url, this.host, this.port);
}
