import 'dart:async';

import 'package:http/http.dart' as http;

import 'http_client.dart';

enum IptvErrorAction { switchToXtream, retry, none }

/// A user-facing (Danish) error with an optional recovery action.
class IptvError {
  final String message;
  final IptvErrorAction action;
  const IptvError(this.message, [this.action = IptvErrorAction.retry]);
}

/// Maps low-level exceptions to friendly messages. Reused by the data layer
/// and the player.
class IptvErrors {
  static IptvError map(Object e) {
    if (e is IptvHttpException) {
      switch (e.statusCode) {
        case 884:
          return const IptvError(
            'Din udbyder blokerer M3U-download (kode 884). Tilføj udbyderen som "Xtream Codes" i stedet.',
            IptvErrorAction.switchToXtream,
          );
        case 401:
        case 403:
          return const IptvError(
            'Forkert brugernavn eller adgangskode.',
            IptvErrorAction.none,
          );
        case 512:
          return const IptvError(
            'Din konto er udløbet eller spærret.',
            IptvErrorAction.none,
          );
        default:
          return IptvError(
            'Serverfejl (HTTP ${e.statusCode}). Prøv igen senere.',
            IptvErrorAction.retry,
          );
      }
    }
    if (e is TimeoutException) {
      return const IptvError(
        'Forbindelsen fik timeout. Tjek dit netværk og prøv igen.',
        IptvErrorAction.retry,
      );
    }
    if (e is http.ClientException) {
      return const IptvError(
        'Kunne ikke få forbindelse til serveren. Tjek dit netværk.',
        IptvErrorAction.retry,
      );
    }
    return IptvError(
      e.toString().replaceFirst('Exception: ', ''),
      IptvErrorAction.retry,
    );
  }
}
