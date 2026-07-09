import 'pairing_models.dart';

/// Web fallback — a local HTTP server needs dart:io (unavailable on web).
class PairingServer {
  static bool get supported => false;

  Future<PairingInfo?> start(
          Future<bool> Function(Map<String, String> fields) onSubmit) async =>
      null;

  Future<void> stop() async {}
}
