import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/tv_mode.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'ui/screens/add_source_screen.dart';
import 'ui/shell/adaptive_scaffold.dart';

class IptvApp extends StatelessWidget {
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      builder: (context, child) {
        if (!isTvMode) return child!;
        // TV: directional navigation makes every row (including ones without
        // a tap handler, e.g. info tiles) focusable, so lists don't dead-end.
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(navigationMode: NavigationMode.directional),
          child: child!,
        );
      },
      home: const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (state.sources.isEmpty) {
      return const AddSourceScreen(isFirstRun: true);
    }
    return const AdaptiveScaffold();
  }
}
