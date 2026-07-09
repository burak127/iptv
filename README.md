# IPTV Player

En cross-platform IPTV-afspiller bygget i **Flutter** — én kodebase til:

- 📱 **Android** (telefon/tablet)
- 📺 **Android TV** (fjernbetjening / D-pad)
- 🌐 **Web**

**V1-funktioner:** Live TV med kategorier og kanalliste. Understøtter både
**M3U/M3U8-playlists** og **Xtream Codes-login**.

> ⚖️ Appen indeholder **intet** indhold. Den afspiller kun de playlists/konti,
> *du selv* indtaster og har ret til at bruge (fx dit eget IPTV-abonnement).

---

## 1. Krav (installeres én gang)

1. **Flutter SDK** — https://docs.flutter.dev/get-started/install/windows
   Udpak fx til `C:\src\flutter` og tilføj `C:\src\flutter\bin` til PATH.
2. **Android Studio** (til Android SDK + emulator/TV-emulator).
   Kør `flutter doctor` og følg anvisningerne, til alt er grønt.

Bekræft med:

```powershell
flutter --version
flutter doctor
```

## 2. Opsætning af projektet

Fra denne mappe (`iptv_player`):

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Scriptet gør følgende automatisk:
1. Sikkerhedskopierer `lib/` + `pubspec.yaml`.
2. Kører `flutter create .` som genererer `android/` og `web/`.
3. Gendanner app-koden ovenpå Flutters skabelon.
4. Indsætter Android TV-manifestet (`platform_templates/AndroidManifest.xml`).
5. Kører `flutter pub get`.

> Vil du gøre det manuelt, er trinnene præcis de samme — se `setup.ps1`.

## 3. Kør appen

```powershell
flutter devices           # vis tilgængelige enheder
flutter run               # telefon / emulator / TV (vælg enhed)
flutter run -d chrome     # webapp i browseren
```

### Android TV
- **Emulator:** opret en *Television*-enhed i Android Studio ▸ Device Manager, start den, og kør `flutter run`.
- **Fysisk TV-boks:** slå *Udvikler-tilstand* + *USB/netværks-fejlretning* til på boksen, forbind med `adb connect <tv-ip>:5555`, og kør `flutter run`.
- **Byg APK til sideload:** `flutter build apk --release` → filen ligger i `build/app/outputs/flutter-apk/app-release.apk`.

## 4. Test med en gratis, lovlig playlist

Har du ikke et abonnement ved hånden, kan du teste med iptv-org's frit tilgængelige liste:

- Vælg **M3U-playlist** i appen
- URL: `https://iptv-org.github.io/iptv/index.m3u`

(Stor liste — vælg en kategori for hurtigere overblik.)

---

## Arkitektur

```
lib/
├── main.dart                 App-indgang + MediaKit-init
├── app.dart                  MaterialApp + start-routing (onboarding vs. home)
├── theme.dart                Mørkt, TV-venligt tema
├── models/
│   ├── iptv_source.dart      M3U- eller Xtream-konfiguration (+ JSON)
│   ├── category.dart         Kanalkategori
│   └── channel.dart          Enkelt kanal
├── services/
│   ├── m3u_parser.dart       Parser #EXTINF/group-title → kanaler
│   ├── xtream_client.dart    player_api.php: kategorier + live-streams
│   ├── source_repository.dart  Gemmer kilder (shared_preferences)
│   └── iptv_repository.dart  Fælles indlæsning uanset kildetype
├── state/
│   └── app_state.dart        Provider/ChangeNotifier — sources, data, valg
└── ui/
    ├── screens/
    │   ├── add_source_screen.dart   Tilføj M3U/Xtream
    │   ├── sources_screen.dart      Skift/slet kilder
    │   ├── home_screen.dart         Kategorier + kanal-grid (responsivt)
    │   └── player_screen.dart       Fuldskærm media_kit-afspiller
    └── widgets/
        ├── focusable_card.dart      D-pad-fokus-highlight (TV)
        └── channel_card.dart        Kanal-felt i grid
```

**Afspiller:** [`media_kit`](https://pub.dev/packages/media_kit) (libmpv) — håndterer
HLS/live/TS og mærkelige codecs langt bedre end Flutters standard-player.

**TV-navigation:** `FocusableActionDetector` giver hvert felt et tydeligt
fokus-highlight og reagerer på OK/Enter/Select. I afspilleren skifter
pil-op/ned (eller Channel Up/Down) kanal.

**Web-note:** På web afspilles streams via browserens muligheder. Ren HLS-live
virker natively i Safari; i Chrome kan visse HLS-streams kræve en senere
`hls.js`-integration. Android er den primære, mest robuste platform.

## Roadmap (næste versioner)

- [ ] EPG / programguide (nu & næste)
- [ ] VOD & serier (Xtream)
- [ ] Favoritter + søgning + "senest set"
- [ ] Forældrekontrol / PIN
- [ ] hls.js-fallback for fuld HLS på web
