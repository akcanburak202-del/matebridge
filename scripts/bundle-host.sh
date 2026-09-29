#!/usr/bin/env bash
# Wraps a SwiftPM executable into a signed .app so macOS keeps TCC permissions
# (Screen Recording, Accessibility) across rebuilds. TCC keys a grant to the bundle ID
# plus the signing identity; an ad-hoc signature changes on every build and loses it.
#
# Usage: ./scripts/bundle-host.sh [options]
#   --package DIR      SwiftPM package directory          (default: host-mac)
#   --product NAME     executable product to bundle        (default: MateBridgeApp)
#   --name NAME        app name, i.e. NAME.app             (default: MateBridge)
#   --bundle-id ID     CFBundleIdentifier                  (default: dev.matebridge.host)
#   --out DIR          output directory                    (default: build)
#   --release          build with -c release               (default: debug)
#
# Signing identity: $MATEBRIDGE_SIGN_IDENTITY (SHA-1 or name) or the first valid
# "Apple Development" identity in the keychain. It is never written into the repo.
# Example (probe): ./scripts/bundle-host.sh --package probes/vdisplay-probe --product vdisplay-probe \
#                    --name MateBridgeVDisplayProbe --bundle-id dev.matebridge.probe.vdisplay
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

package=host-mac product=MateBridgeApp name=MateBridge bundle_id=dev.matebridge.host out=build config=debug
while [ $# -gt 0 ]; do
  case "$1" in
    --package) package=${2:?}; shift 2 ;;
    --product) product=${2:?}; shift 2 ;;
    --name) name=${2:?}; shift 2 ;;
    --bundle-id) bundle_id=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --release) config=release; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$package/Package.swift" ] || { echo "no Package.swift in $package" >&2; exit 2; }

identity=${MATEBRIDGE_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning | awk '/"Apple Development: /{print $2; exit}')
fi
if [ -z "$identity" ]; then
  cat >&2 <<'MSG'
No valid "Apple Development" signing identity found.
Sign in with your Apple ID in Xcode > Settings > Apple Accounts, then Manage Certificates > + > Apple Development.
If the certificate exists but is not valid, install Apple's WWDR G3 intermediate (see docs/NOTES.md, 2026-09-29).
MSG
  exit 1
fi

echo "==> swift build -c $config --product $product ($package)"
(cd "$package" && swift build -c "$config" --product "$product")
bin_dir=$(cd "$package" && swift build -c "$config" --show-bin-path)
[ -x "$bin_dir/$product" ] || { echo "built product not found: $bin_dir/$product" >&2; exit 1; }

app="$out/$name.app"
echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/$product" "$app/Contents/MacOS/$product"
# SwiftPM resource bundles, if the product has any.
for b in "$bin_dir"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done

build_number=$(date +%Y%m%d%H%M%S)
sed -e "s/__EXECUTABLE__/$product/g" -e "s/__BUNDLE_ID__/$bundle_id/g" \
    -e "s/__NAME__/$name/g" -e "s/__BUILD__/$build_number/g" \
    "$root/host-mac/Resources/Info.plist" > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

echo "==> signing with identity ${identity:0:8}…"
codesign --force --sign "$identity" --timestamp=none \
  --entitlements "$root/host-mac/Resources/MateBridge.entitlements" "$app"
codesign --verify --strict "$app"
codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => /designated requirement: /p'
echo "OK: $app"
