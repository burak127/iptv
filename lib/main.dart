import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/download_manager.dart';
import 'services/tls_overrides.dart';
import 'services/tv_mode.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tolerate providers' self-signed/expired HTTPS certs (see TlsOverrides).
  TlsOverrides.install();
  MediaKit.ensureInitialized();
  // Bound logo/poster decode memory — a 7000-channel catalog on a 1.5GB TV box
  // would otherwise evict-thrash or OOM the image cache.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20; // 48MB
  await detectTvMode();
  await loadVideoPrefs();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()..init()),
        ChangeNotifierProvider(create: (_) => DownloadManager()),
      ],
      child: const IptvApp(),
    ),
  );
}
