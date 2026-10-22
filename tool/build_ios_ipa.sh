#!/usr/bin/env bash
# Builds the iPhone app as an .ipa that can be sideloaded with AltStore or
# Sideloadly using a FREE Apple ID. macOS + Xcode only; run `flutter pub get`
# first. Used by .github/workflows/ios-ipa.yml and codemagic.yaml.
#
#   bash tool/build_ios_ipa.sh [output.ipa]
#
# ── Hard-won knowledge (2026-07-10) ─────────────────────────────────────────
# AltServer signs apps with a vendored old `ldid` that hard-asserts
#   ldid.cpp(1461): _assert(): end >= size - 0x10
# unless every Mach-O's code-signature blob starts within 16 bytes of the
# symbol string-table end. Two states BOTH fail that check on this app:
#   1. The raw build output: media_kit/libmpv prebuilt dylibs ship with
#      page-gapped signature offsets (same as Spotube/Kazumi/AnymeX/Fladder —
#      all media_kit Flutter apps, all hit this exact assert).
#   2. Signature-STRIPPED binaries (codesign --remove-signature): documented
#      in Fladder #36/#800 — "completely unsigned inner Flutter frameworks"
#      trigger the same assert. Stripping is the WRONG fix.
# The CONFIRMED fix (AnymeX PR #93, merged with install proof; endorsed by
# Kazumi's maintainer; Fladder screenshots) is to RE-SIGN everything with a
# fresh dummy signature so each binary gets a compact, well-aligned
# LC_CODE_SIGNATURE that old ldid can parse and then overwrite with the free
# Apple ID. We use Apple's own `codesign -f -s -` (ad-hoc, zero secrets).
# tool/ldid_gate.py re-implements ldid's exact assert arithmetic and FAILS
# THE BUILD if any binary would still trip it — no more blind downloads.
#
# Never re-zip the .ipa on Windows: AltStore rejects that container. Always
# package on the Mac that built it (the last step below).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

OUT="${1:-build/ios/iphoneos/iptv_player-unsigned.ipa}"
APP="build/ios/iphoneos/Runner.app"

echo "==> Building iOS app (no distribution signing)"
flutter build ios --release --no-codesign

# Re-sign, do NOT strip. Bottom-up: frameworks first, then the app shell.
# Stale _CodeSignature seals are removed first; codesign regenerates them
# consistently.
echo "==> Ad-hoc re-signing every framework + the app"
find "$APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
for fw in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib; do
  [ -e "$fw" ] || continue
  codesign --force --sign - --timestamp=none "$fw"
  echo "re-signed: $fw"
done
codesign --force --sign - --timestamp=none "$APP"
echo "re-signed app shell: $APP"

echo "==> Gate: every binary must pass AltServer's ldid assert"
python3 "$(dirname "$0")/ldid_gate.py" "$APP"

echo "==> Packaging Runner.app into the .ipa"
mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
STAGE="$(mktemp -d)"
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT_ABS"
(cd "$STAGE" && zip -qr9 "$OUT_ABS" Payload)
rm -rf "$STAGE"
echo "IPA ready: $OUT"
