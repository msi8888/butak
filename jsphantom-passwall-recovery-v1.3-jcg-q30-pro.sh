#!/bin/sh
# JsPhantom PassWall 1 recovery installer for ImmortalWrt 25.12 / aarch64
# Tested target versions: PassWall 26.4.15-r1 and Xray 26.3.27.
# v1.3 JCG Q30 PRO: safe Xray replacement, download-first, rollback, preserve PassWall 2.
set -u
PW_URL='https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/26.4.15-1/25.12%2B_luci-app-passwall-26.4.15-r1.apk'
XR_URL='https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-arm64-v8a.zip'
WORK='/tmp/jsphantom-passwall-recovery'
BACKUP='/root/jsphantom-passwall-recovery-backup'
log(){ printf '\n[JsPhantom] %s\n' "$*"; }
fail(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }
ask(){ printf '%s' "$1"; IFS= read -r ANSWER || ANSWER=''; }
[ "$(id -u)" = 0 ] || fail 'Run as root.'
[ -f /etc/openwrt_release ] || fail 'This is not OpenWrt/ImmortalWrt.'
. /etc/openwrt_release
case "${DISTRIB_RELEASE:-}" in 25.12*) ;; *) fail "Only 25.12.x is supported; detected ${DISTRIB_RELEASE:-unknown}.";; esac
case "${DISTRIB_ARCH:-}" in aarch64_cortex-a53|aarch64_generic) ;; *) fail "Architecture not validated: ${DISTRIB_ARCH:-unknown}. Expected aarch64.";; esac
need apk; need curl; need uci; need df; need awk
[ "${DISTRIB_TARGET:-}" = 'mediatek/filogic' ] || fail 'v1.2 targets JCG Q30 PRO on mediatek/filogic only.'
[ "${DISTRIB_ARCH:-}" = 'aarch64_cortex-a53' ] || fail 'Expected aarch64_cortex-a53.'
[ -x /etc/init.d/passwall ] || fail 'PassWall 1 init script is missing.'
[ -f /etc/config/passwall ] || fail 'PassWall 1 config missing.'
[ "$(uci -q get 'passwall2.@global[0].enabled' || echo 0)" = 0 ] || fail 'PassWall 2 is enabled. Disable it manually first; installer will not touch it.'
[ "$(uci -q get 'passwall.@global[0].enabled' || echo 0)" = 0 ] || fail 'PassWall 1 is currently enabled. Stop it manually from LAN before installation.'

need unzip
[ -x /usr/bin/xray ] || fail 'Existing /usr/bin/xray is missing.'

log 'JsPhantom PassWall Recovery v1.3 - JCG Q30 PRO'
printf 'Firmware: %s %s (%s)\n' "${DISTRIB_ID:-ImmortalWrt}" "$DISTRIB_RELEASE" "${DISTRIB_ARCH:-unknown}"
printf 'PassWall: 26.4.15-r1 | Xray: 26.3.27\n'
printf 'WARNING: Proxy service may interrupt connectivity; use local LAN SSH if possible.\n'
ask 'Continue? [y/N]: '
case "$ANSWER" in y|Y|yes|YES) ;; *) exit 0;; esac
# All downloads and version validation happen before modifying the router.
mkdir -p "$WORK" "$BACKUP" || fail 'Cannot create work directories.'
log 'Downloading pinned PassWall APK and Xray into RAM (/tmp)'
curl -4 -fL --retry 3 --connect-timeout 15 -o "$WORK/passwall.apk" "$PW_URL" || fail 'PassWall download failed.'
[ "$(wc -c < "$WORK/passwall.apk")" -gt 100000 ] || fail 'PassWall APK suspiciously small.'
curl -4 -fL --retry 3 --connect-timeout 15 -o "$WORK/xray.zip" "$XR_URL" || fail 'Xray download failed.'
[ "$(wc -c < "$WORK/xray.zip")" -gt 1000000 ] || fail 'Xray ZIP suspiciously small.'
mkdir -p "$WORK/extracted" || fail 'Cannot create extract directory.'
unzip -oq "$WORK/xray.zip" 'xray' -d "$WORK/extracted" || fail 'Xray extraction failed.'
chmod 755 "$WORK/extracted/xray"
XRAY_DOWNLOADED_VERSION=$("$WORK/extracted/xray" version 2>&1 | sed -n '1p')
case "$XRAY_DOWNLOADED_VERSION" in
 'Xray 26.3.27 '*) log "Verified archive: $XRAY_DOWNLOADED_VERSION" ;;
 *) fail "Unexpected Xray version in archive: $XRAY_DOWNLOADED_VERSION" ;;
esac
log 'Verifying temporary and overlay capacity'
# Keep old Xray in RAM to permit rollback without writing another 31 MB to flash.
OLD_SIZE=$(wc -c < /usr/bin/xray)
NEW_SIZE=$(wc -c < "$WORK/extracted/xray")
TMP_FREE=$(df -k /tmp | awk 'END{print $4*1024}')
OVL_FREE=$(df -k /overlay | awk 'END{print $4*1024}')
[ "$TMP_FREE" -gt $((OLD_SIZE + 8388608)) ] || fail 'Not enough /tmp RAM to back up old Xray safely.'
# The old binary will be removed before the new one is copied, so the old size is reclaimed.
[ $((OVL_FREE + OLD_SIZE)) -gt $((NEW_SIZE + 8388608)) ] || fail 'Not enough overlay capacity for safe Xray replacement.'
log 'Backing up original PassWall config and Xray (Xray backup in /tmp only)'
cp -p /etc/config/passwall "$BACKUP/passwall.$(date +%Y%m%d-%H%M%S)" || fail 'Cannot backup PassWall config.'
cp -p /usr/bin/xray "$WORK/xray-old" || fail 'Cannot back up old Xray to RAM.'
chmod 755 "$WORK/xray-old"
log 'Installing pinned PassWall 26.4.15-r1 (PassWall 2 remains untouched)'
if ! apk add --allow-untrusted "$WORK/passwall.apk"; then
 fail 'PassWall APK install failed. Xray remains unchanged. Check dependency feeds.'
fi
PASSWALL_INSTALLED=$(apk list -I 2>/dev/null | grep '^luci-app-passwall-' | head -1)
case "$PASSWALL_INSTALLED" in
 'luci-app-passwall-26.4.15-r1 '*) log "Verified package: $PASSWALL_INSTALLED" ;;
 *) fail "Unexpected PassWall version: $PASSWALL_INSTALLED; Xray remains unchanged." ;;
esac
log 'Replacing Xray in storage-safe mode'
# Save flash space: old binary is backed up in /tmp, then deleted before installing new.
rm -f /usr/bin/xray || fail 'Cannot remove old Xray.'
if ! cp "$WORK/extracted/xray" /usr/bin/xray; then
 log 'ERROR: Xray copy failed; restoring original from RAM.'
 rm -f /usr/bin/xray
 cp "$WORK/xray-old" /usr/bin/xray || fail 'CRITICAL: Xray restore failed. Backup at /tmp/jsphantom-passwall-recovery/xray-old; do not reboot.'
 chmod 755 /usr/bin/xray
 fail 'Xray replacement failed; original binary restored.'
fi
chmod 755 /usr/bin/xray
XRAY_INSTALLED_VERSION=$(/usr/bin/xray version 2>&1 | sed -n '1p')
case "$XRAY_INSTALLED_VERSION" in
 'Xray 26.3.27 '*) XRAY_VERSION_OK=1 ;;
 *) XRAY_VERSION_OK=0 ;;
esac
if [ "$XRAY_VERSION_OK" -ne 1 ]; then
 log 'ERROR: New Xray version mismatch; restoring original from RAM.'
 rm -f /usr/bin/xray
 cp "$WORK/xray-old" /usr/bin/xray || fail 'CRITICAL: Restore failed; do not reboot.'
 chmod 755 /usr/bin/xray
 fail 'Xray version verification failed; original restored.'
fi
log "Xray installed and verified: $XRAY_INSTALLED_VERSION"
log 'Configuring VLESS WS non-TLS'
if [ -f /etc/config/passwall ]; then
 EXISTING=$(uci -q show passwall | grep -E "\.protocol='vless'" | head -1 | cut -d. -f2)
else EXISTING=''; fi
if [ -n "$EXISTING" ]; then
 printf 'Existing VLESS section found: %s\n' "$EXISTING"
 ask 'Use existing VLESS configuration? [Y/n]: '
 case "$ANSWER" in n|N|no|NO) EXISTING='';; esac
fi
if [ -n "$EXISTING" ]; then
 NODE="$EXISTING"
else
 NODE='jsphantom_vless'
 printf '\nEnter VLESS settings (from your VPN provider).\n'
 ask 'VLESS UUID: '; UUID="$ANSWER"
 ask 'Server IP or domain: '; SERVER="$ANSWER"
 ask 'Server port [80]: '; PORT="${ANSWER:-80}"
 ask 'WebSocket Host header: '; HOST="$ANSWER"
 ask 'WebSocket path [/vless]: '; PATH_WS="${ANSWER:-/vless}"
 case "$UUID" in ????????-????-????-????-????????????) ;; *) fail 'Invalid UUID format.';; esac
 [ -n "$SERVER" ] && [ -n "$HOST" ] || fail 'Server and Host must not be empty.'
 case "$PORT" in *[!0-9]*|'') fail 'Port must be numeric.';; esac
 [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail 'Invalid port.'
 case "$PATH_WS" in /*) ;; *) fail 'WebSocket path must start with /.';; esac
 uci -q delete "passwall.$NODE" || true
 uci set "passwall.$NODE=nodes"
 uci set "passwall.$NODE.remarks=JsPhantom-VLESS-WS"
 uci set "passwall.$NODE.type=Xray"
 uci set "passwall.$NODE.protocol=vless"
 uci set "passwall.$NODE.address=$SERVER"
 uci set "passwall.$NODE.port=$PORT"
 uci set "passwall.$NODE.uuid=$UUID"
 uci set "passwall.$NODE.encryption=none"
 uci set "passwall.$NODE.transport=ws"
 uci set "passwall.$NODE.ws_host=$HOST"
 uci set "passwall.$NODE.ws_path=$PATH_WS"
 uci set "passwall.$NODE.tls=0"
fi
if ! uci -q get 'passwall.@global[0]' >/dev/null 2>&1; then uci add passwall global >/dev/null; fi
if ! uci -q get 'passwall.@global_app[0]' >/dev/null 2>&1; then uci add passwall global_app >/dev/null; fi
if ! uci -q get 'passwall.@global_delay[0]' >/dev/null 2>&1; then uci add passwall global_delay >/dev/null; fi
uci set 'passwall.@global_delay[0].start_delay=30' || fail 'Cannot set boot delay.'
uci set "passwall.@global_app[0].xray_file=/usr/bin/xray"
uci set "passwall.@global[0].node=$NODE"
uci set "passwall.@global[0].tcp_node=$NODE"
uci set 'passwall.@global[0].udp_node=tcp'
uci set 'passwall.@global[0].tcp_proxy_mode=proxy'
uci set 'passwall.@global[0].udp_proxy_mode=proxy'
uci set 'passwall.@global[0].enabled=0'
uci commit passwall || fail 'Cannot save UCI configuration.'
log 'Installed versions'
apk list -I | grep '^luci-app-passwall-'
xray version | head -1
printf 'Selected node: %s\n' "$NODE"
printf 'Boot delay: %s seconds\n' "$(uci -q get 'passwall.@global_delay[0].start_delay')"
printf '\nThe installer will now start PassWall for a health check.\n'
ask 'Start PassWall now? [y/N]: '
case "$ANSWER" in y|Y|yes|YES) ;; *) log 'Installation completed; PassWall remains OFF.'; exit 0;; esac
uci set 'passwall.@global[0].enabled=1'; uci commit passwall
if ! /etc/init.d/passwall restart; then
 /etc/init.d/passwall stop || true
 uci set 'passwall.@global[0].enabled=0'; uci commit passwall
 fail 'PassWall restart failed; reverted to OFF.'
fi
sleep 6
if ! pgrep -f '/tmp/etc/passwall/bin/xray run' >/dev/null 2>&1; then
 tail -45 /tmp/log/passwall.log 2>/dev/null || true
 /etc/init.d/passwall stop || true
 uci set 'passwall.@global[0].enabled=0'; uci commit passwall
 fail 'Xray did not start; PassWall reverted to OFF.'
fi
log 'SUCCESS: Xray process is running.'
if /etc/init.d/passwall enable && /etc/init.d/passwall enabled; then
 log 'Autostart: ENABLED | Boot delay: 30 seconds'
else
 log 'WARNING: PassWall autostart could not be confirmed; check /etc/rc.d/S99passwall.'
fi
if command -v netstat >/dev/null 2>&1; then
 if netstat -lnt 2>/dev/null | grep -q ':1041[[:space:]]'; then
  log 'Local proxy port 1041: LISTEN'
 else
  log 'WARNING: Local proxy port 1041 was not detected; inspect PassWall logs.'
 fi
fi
pgrep -af xray || true
printf '\nPublic IPv4 from router (check against expected VPS IP):\n'
curl -4 -sS --max-time 12 https://api.ipify.org || true
printf '\n'
printf 'IMPORTANT: Confirm the public IP and test from a LAN device. A running Xray process alone does not prove proxy routing.\n'
