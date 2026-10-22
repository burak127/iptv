# IPTV Player

En cross-platform IPTV-afspiller bygget i **Flutter**. Én kodebase til:

- 📱 **Android** (telefon/tablet)
- 📺 **Android TV / Google TV** (fjernbetjening/D-pad, kan starte automatisk som kiosk)
- 🍏 **iPhone/iPad** (sideload med gratis Apple-ID)
- 🪟 **Windows**
- 🌐 **Web** (delvist)

Understøtter **M3U/M3U8-playlister** og **Xtream Codes-login**.

> ⚖️ Appen indeholder **intet** indhold. Den afspiller kun de playlister/konti,
> *du selv* indtaster og har ret til at bruge (fx dit eget IPTV-abonnement).

## Funktioner

- Live-tv med kategorier, tv-guide (EPG) og op til **12 timers spoling tilbage** på kanaler med arkiv (Xtream catch-up)
- Film og serier (Xtream) med "fortsæt hvor du slap" og automatisk næste afsnit
- Søgning, favoritter, senest sete samt skjul/sortér kategorier
- Undertekster: indbyggede spor + søgning efter eksterne undertekster
- Dobbelt-tap i venstre/højre side spoler (Netflix-agtigt), sleep-timer og billedformater
- Forældre-PIN, downloads og flere kilder, som kan redigeres
- Tilføj en kilde fra telefonen ved at scanne en QR-kode på tv'et

---

## Download

Færdige filer ligger under [**Releases**](https://github.com/burak127/iptv/releases):

| Platform | Fil | Sådan |
|---|---|---|
| Android / Android TV | `.apk` | Åbn filen på enheden (tillad "ukendte apps") eller `adb install` |
| Windows | `-windows-x64.zip` | Pak **hele** mappen ud og kør `iptv_player.exe` |
| iPhone/iPad | `-ios.ipa` | Se næste afsnit |

## Installér på iPhone

Apple tillader ikke apps udenom App Store, men med et **gratis Apple-ID** kan du selv
signere og installere `.ipa`-filen:

**AltStore (testet, fornyer automatisk)**
1. Installér AltServer på din pc fra [altstore.io](https://altstore.io) (på Windows kræves iTunes og iCloud fra Apples hjemmeside, ikke Microsoft Store), og brug den til at installere AltStore på iPhonen.
2. Hent `iptv-player-…-ios.ipa` fra Releases på iPhonen.
3. Åbn AltStore ▸ **My Apps** ▸ **+** ▸ vælg filen og log ind med dit Apple-ID.
4. På iPhonen: slå **Udviklertilstand** til (Indstillinger ▸ Anonymitet og sikkerhed) og stol på dit Apple-ID under Indstillinger ▸ Generelt ▸ VPN og enhedsadministration.

**Sideloadly** ([sideloadly.io](https://sideloadly.io)) bør også virke: tilslut iPhonen med kabel, træk `.ipa`-filen ind og tryk Start.

> Med et gratis Apple-ID udløber appen efter **7 dage**. AltStore fornyer den automatisk,
> når iPhonen og pc'en med AltServer er på samme wifi.

---

## Byg og redigér selv

**Krav:** [Flutter](https://docs.flutter.dev/get-started/install) 3.44.4 (stable). Tjek med `flutter doctor`.

```powershell
flutter pub get
flutter run                 # vælg telefon/emulator/TV
flutter run -d windows      # Windows-app
flutter run -d chrome       # webapp
```

**Release-builds**

- **Android:** `flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`.
  Repoet har ingen release-nøgle, så APK'en signeres med din egen debug-nøgle. En app, der er installeret
  fra en anden pc's build, skal derfor afinstalleres før opdatering.
- **Windows:** `flutter build windows --release` → hele mappen `build/windows/x64/runner/Release/`.
- **iPhone uden Mac:** fork repoet ▸ fanen **Actions** ▸ **iOS IPA (sideload)** ▸ **Run workflow**.
  Efter ca. 5 minutter ligger `.ipa`-filen under run'ets *Artifacts*. GitHub stiller Mac'en gratis til rådighed for offentlige repoer.
- **iPhone med Mac:** `flutter pub get` og derefter `bash tool/build_ios_ipa.sh`.

Byggescriptet gen-signerer alle frameworks og stopper buildet, hvis AltStore ville afvise en fil
(forklaringen står i toppen af `tool/build_ios_ipa.sh`).

**Ny udgivelse:** et annoteret tag bygger automatisk `.ipa`-filen og lægger den på releasen.
Tagbeskeden bliver releasens titel og tekst:

```powershell
git tag -a v1.4.0 -m "v1.4.0 — kort titel" -m "Hvad er nyt…"
git push origin v1.4.0
```

**Tests:** `flutter test` og `flutter analyze`.

### Android TV
- **Emulator:** opret en *Television*-enhed i Android Studio ▸ Device Manager og kør `flutter run`.
- **Fysisk boks:** slå *Udviklertilstand* og *netværks-fejlretning* til på boksen, forbind med
  `adb connect <boksens-ip>:5555` og kør `flutter run` eller `adb install -r app-release.apk`.

### Test med en gratis, lovlig playlist

Vælg **M3U-playlist** i appen og brug `https://iptv-org.github.io/iptv/index.m3u`
(stor liste, så vælg en kategori for hurtigere overblik).

---

## Arkitektur

```
lib/
├── main.dart, app.dart   Opstart, tema og routing (første kilde vs. hjem)
├── models/               Kilder, kanaler, film, serier, EPG
├── services/             M3U-, Xtream- og XMLTV-klienter, cache, stream-URL'er,
│                         undertekster, arkivspoling og platformtjenester
├── state/                AppState (kilder, kataloger, favoritter, resume)
│                         og PlaybackController (afspilleren)
└── ui/                   Skærme (live, film, serier, guide, søg, afspiller …)
                          og widgets (TV-fokus, eget skærmtastatur)
android/   Native ExoPlayer-afspiller til svage TV-bokse, PiP og autostart
ios/       Xcode-projektet (Info.plist tillader http-streams)
windows/   Desktop-runner
tool/      iOS-byggescript og AltStore-kontrol
```

**Afspiller:** [`media_kit`](https://pub.dev/packages/media_kit) (libmpv) på alle platforme. Den håndterer
HLS/live/TS og mærkelige codecs langt bedre end Flutters standardafspiller. På Android TV kan
man i indstillingerne skifte til den native ExoPlayer-afspiller, der kører glattere på svage bokse.

**TV-navigation:** alle felter har et tydeligt fokus-highlight og reagerer på OK/Enter. I afspilleren
skifter pil-op/ned (eller Channel Up/Down) kanal.

## Licens

[MIT](LICENSE): du må frit bruge, ændre og dele koden, også i dine egne projekter, så længe
copyright-linjen følger med.
