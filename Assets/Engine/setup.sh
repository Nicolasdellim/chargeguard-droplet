#!/bin/bash
set -euo pipefail
ENGINE=/Library/PrivilegedHelperTools/local.chargeguard.batt
STATE='/Library/Application Support/ChargeGuard'
PLIST=/Library/LaunchDaemons/local.chargeguard.batt.plist
SOCKET=/var/run/chargeguard-batt.sock
LABEL=local.chargeguard.batt
SOURCE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo 'Administrator privileges required.' >&2; exit 1; }
command_engine() { "$ENGINE" --config "$STATE/batt.json" --daemon-socket "$SOCKET" "$@"; }
case "${1:-}" in
install)
    [ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required.' >&2; exit 1; }
    # Refuse competing controllers rather than taking over their hardware state.
    for file in /Library/LaunchDaemons/cc.chlc.batt.plist /Library/LaunchDaemons/homebrew.mxcl.batt.plist /Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro.helper /Library/PrivilegedHelperTools/com.apphousekitchen.aldente.helper; do
        [ ! -e "$file" ] || { echo "Un autre contrôleur de batterie est installé : $file. Désinstallez-le avant de continuer." >&2; exit 1; }
    done
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        command_engine disable
        /bin/launchctl bootout "system/$LABEL"
    fi
    /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools "$STATE"
    /usr/bin/install -o root -g wheel -m 755 "$SOURCE/batt" "$ENGINE"
    if [ ! -f "$STATE/batt.json" ]; then
        # Start unrestricted. The user applies a range after hardware probing.
        cat > "$STATE/batt.json" <<'JSON'
{"limit":100,"lowerLimitDelta":60,"allowNonRootAccess":true,"preventIdleSleep":false,"preventSystemSleep":false,"disableChargingPreSleep":true}
JSON
    fi
    /usr/sbin/chown root:wheel "$STATE/batt.json"
    /bin/chmod 600 "$STATE/batt.json"
    cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.chargeguard.batt</string>
<key>ProgramArguments</key><array>
<string>/Library/PrivilegedHelperTools/local.chargeguard.batt</string>
<string>--config</string><string>/Library/Application Support/ChargeGuard/batt.json</string>
<string>--daemon-socket</string><string>/var/run/chargeguard-batt.sock</string>
<string>daemon</string><string>--always-allow-non-root-access</string>
</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/Library/Application Support/ChargeGuard/engine.log</string>
<key>StandardErrorPath</key><string>/Library/Application Support/ChargeGuard/engine.log</string>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
    /usr/sbin/chown root:wheel "$PLIST"
    /bin/chmod 644 "$PLIST"
    /bin/launchctl bootstrap system "$PLIST"
    echo 'Charge Guard : moteur installé.'
    ;;
uninstall)
    if [ -x "$ENGINE" ]; then
        # Do not remove the helper unless restoring charging succeeds.
        command_engine disable
    fi
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$LABEL"
    fi
    /bin/rm -f "$PLIST" "$ENGINE" "$SOCKET"
    echo 'Charge normale rétablie ; moteur désinstallé. Les journaux restent disponibles.'
    ;;
*) echo 'Usage: setup.sh install|uninstall' >&2; exit 2;;
esac
