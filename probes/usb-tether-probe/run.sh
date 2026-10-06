#!/usr/bin/env bash
# T-273 Mac-side driver for the USB tethering probe. Tablet access ONLY over wireless adb
# (USB adb drops as soon as the USB function changes). Read-only on the Mac: no network
# service changes, nothing that needs an admin password, no windows.
#
# Usage: run.sh build | push | tp ARGS... | app ARGS... | status | mac | try MODE | measure [MAC_IP] | restore
#   tp ARGS   run the helper as the adb shell user (uid 2000), e.g. "tp start usb"
#   app ARGS  run the helper as the MateBridge app uid (run-as), e.g. "app rtt 192.168.42.10 47900 200"
#   try MODE  usb-ncm | ncm | usb-rndis | legacy-ncm : one full attempt (start, wait, status, mac,
#             measure if the Mac got an address) and ALWAYS restore at the end
#   measure   temporary echo/sink listener on the Mac tether address (ports 47900/47901), then
#             RTT and throughput from the app uid (and the shell uid for comparison)
#   restore   stop tethering, delete tether_force_usb_functions, USB back to hisuite,mtp,mass_storage,adb, verify
set -uo pipefail
cd "$(dirname "$0")"

ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
DEV="${DEV:-192.168.1.105:5555}"
PKG=dev.matebridge.client
JAR_DEV=/data/local/tmp/usb-tether-probe.jar
APP_JAR=cache/t273-usb-tether-probe.jar # relative to the app data dir (run-as cwd)
MAIN=dev.matebridge.probe.usbtether.TetherProbe
DEFAULT_USB=hisuite,mtp,mass_storage,adb
ECHO_PORT=47900
SINK_PORT=47901
TS() { date +%H:%M:%S; }

# adbd restarts when the USB function changes, which also drops the wireless connection:
# reconnect and retry (up to ~20 s) whenever adb reports the device offline/missing.
a() {
  local i out rc
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$("$ADB" -s "$DEV" "$@" 2>&1); rc=$?
    case $out in
      *"device offline"*|*"not found"*|*"no devices"*|*"error: closed"*)
        "$ADB" disconnect "$DEV" >/dev/null 2>&1; sleep 2; "$ADB" connect "$DEV" >/dev/null 2>&1; continue ;;
    esac
    # adb exits 255 with no output when the connection dropped mid-command: retry (stop/restore are idempotent)
    if [ $rc -eq 255 ] && [ -z "$out" ]; then
      "$ADB" connect "$DEV" >/dev/null 2>&1; sleep 2; continue
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
    return $rc
  done
  echo "adb: $DEV unreachable after retries" >&2
  return 1
}
tp() { a shell "CLASSPATH=$JAR_DEV app_process / $MAIN $*"; }
app() {
  a shell "cat $JAR_DEV | run-as $PKG sh -c 'cat > $APP_JAR' && run-as $PKG sh -c 'CLASSPATH=/data/data/$PKG/$APP_JAR app_process / $MAIN $*'; run-as $PKG rm -f $APP_JAR"
}

status() {
  echo "--- tablet status $(TS)"
  a shell 'echo "usb config=$(getprop sys.usb.config) state=$(getprop sys.usb.state)"
    echo "tether_force_usb_functions=$(settings get global tether_force_usb_functions)"
    ip -br addr | grep -E "^(ncm|rndis|usb)" || echo "(no ncm/rndis/usb iface)"
    dumpsys tethering | sed -n "/Configuration:/,/Entitlement:/p" | grep -E "mUsbTetheringFunction|tetherableUsbRegexs|tetherableNcmRegexs"
    dumpsys tethering | sed -n "/Tether state:/,/Current upstream/p"
    echo "tethering log (last 8):"
    dumpsys tethering | sed -n "/^  Log:/,\$p" | tail -8 | cut -c1-220'
}

# Mac tether interface = hardware port named after the tablet model (CDC-NCM), if present
mac_iface() { networksetup -listallhardwareports | awk '/Hardware Port: MRDI/{getline; print $2; exit}'; }

mac() {
  echo "--- mac status $(TS)"
  local ifc; ifc=$(mac_iface)
  if [ -n "$ifc" ] && ifconfig "$ifc" >/dev/null 2>&1; then
    ifconfig "$ifc" | grep -E "flags|inet |status|media" | sed "s/^/  $ifc: /"
    echo "  ipconfig getifaddr $ifc: $(ipconfig getifaddr "$ifc" || echo none)"
  else
    echo "  no MRDI tether interface present (iface='${ifc:-?}')"
  fi
  echo "  default route: $(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  echo "  service order: $(networksetup -listnetworkserviceorder | grep -E '^\([0-9]+\)' | tr '\n' ' ')"
}

mac_addr() { local ifc; ifc=$(mac_iface); [ -n "$ifc" ] && ipconfig getifaddr "$ifc" 2>/dev/null; }

measure() {
  local ip=${1:-$(mac_addr)}
  [ -n "$ip" ] || { echo "measure: Mac has no tether IPv4 address"; return 1; }
  echo "--- measure against $ip $(TS)"
  python3 mac_server.py "$ip" $ECHO_PORT $SINK_PORT > build/mac_server.log 2>&1 &
  local srv=$!
  sleep 1
  echo "[app uid] rtt";  app rtt "$ip" $ECHO_PORT 500
  echo "[app uid] tput"; app tput "$ip" $SINK_PORT 5
  echo "[shell uid] rtt"; tp rtt "$ip" $ECHO_PORT 200
  kill $srv 2>/dev/null; wait $srv 2>/dev/null
  sed 's/^/  server: /' build/mac_server.log
}

restore() {
  echo "--- restore $(TS)"
  tp stopall
  tp stop usb
  tp stop ncm
  a shell settings delete global tether_force_usb_functions
  local cfg i
  for i in $(seq 1 10); do
    cfg=$(a shell getprop sys.usb.config | tr -d '\r')
    [ "$cfg" = "$DEFAULT_USB" ] && break
    sleep 1
  done
  if [ "$cfg" != "$DEFAULT_USB" ]; then
    echo "usb config is '$cfg', resetting functions"
    a shell svc usb setFunctions
    for i in $(seq 1 10); do
      cfg=$(a shell getprop sys.usb.config | tr -d '\r')
      [ "$cfg" = "$DEFAULT_USB" ] && break
      sleep 1
    done
  fi
  local force; force=$(a shell settings get global tether_force_usb_functions | tr -d '\r')
  if [ "$cfg" = "$DEFAULT_USB" ] && [ "$force" = null ]; then
    echo "RESTORE OK: usb=$cfg tether_force_usb_functions=$force"
  else
    echo "RESTORE INCOMPLETE: usb=$cfg tether_force_usb_functions=$force"
    return 1
  fi
}

try() {
  local mode=$1
  trap 'restore' EXIT
  status; mac
  echo "=== try $mode $(TS)"
  case $mode in
    usb-ncm)    a shell settings put global tether_force_usb_functions 1; sleep 1; tp start usb ;;
    usb-rndis)  tp start usb ;;
    ncm)        a shell svc usb setFunctions ncm; sleep 3; tp start ncm ;;
    ncm-local)  a shell svc usb setFunctions ncm; sleep 3; tp start ncm local ;;
    legacy-ncm) a shell settings put global tether_force_usb_functions 1; sleep 1; tp legacy-usb on ;;
    tether-ncm0) a shell svc usb setFunctions ncm; sleep 3; tp tether ncm0 ;;
    *) echo "unknown mode $mode"; return 2 ;;
  esac
  for i in 3 3 4; do sleep $i; status; mac; done
  if [ -n "$(mac_addr)" ]; then measure; fi
}

cmd=${1:-}; shift || true
case $cmd in
  build) ./build.sh ;;
  push) a push build/usb-tether-probe.jar $JAR_DEV ;;
  tp) tp "$@" ;;
  app) app "$@" ;;
  status) status ;;
  mac) mac ;;
  measure) mkdir -p build; measure "$@" ;;
  restore) restore ;;
  try) mkdir -p build; try "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
