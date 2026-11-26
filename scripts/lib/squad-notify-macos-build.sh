#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || exit 0
force=0 quiet=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --quiet) quiet=1 ;;
    *) printf 'squad-notifier: unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
command -v swiftc >/dev/null 2>&1 || { printf 'squad-notifier: swiftc not found\n' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_path="${SQUAD_DEVKIT_NOTIFY_APP:-${XDG_DATA_HOME:-$HOME/.local/share}/squad-devkit/SquadNotifier.app}"
if command -v shasum >/dev/null 2>&1; then
  stamp="$(cat "$script_dir/squad-notify-macos.swift" "$script_dir/squad-notify-macos-build.sh" | shasum -a 256 | cut -d ' ' -f 1)"
else
  stamp="$(cat "$script_dir/squad-notify-macos.swift" "$script_dir/squad-notify-macos-build.sh" | sha256sum | cut -d ' ' -f 1)"
fi
if (( ! force )) && [[ -x "$app_path/Contents/MacOS/squad-notifier" && -f "$app_path/Contents/Resources/source.sha256" ]] && [[ "$(cat "$app_path/Contents/Resources/source.sha256")" == "$stamp" ]]; then
  (( quiet )) || printf 'squad-notifier: up to date\n'
  exit 0
fi
parent="$(dirname "$app_path")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.squad-notifier.XXXXXXXX")"
backup=""
cleanup() {
  if [[ -n "$backup" && -e "$backup" && ! -e "$app_path" ]]; then mv "$backup" "$app_path" || true; fi
  rm -rf "$stage"
}
trap cleanup EXIT
stage_app="$stage/SquadNotifier.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
swiftc -O -framework Cocoa -framework UserNotifications "$script_dir/squad-notify-macos.swift" -o "$stage_app/Contents/MacOS/squad-notifier"
printf '%s\n' "$stamp" > "$stage_app/Contents/Resources/source.sha256"
cat > "$stage_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.squad-devkit.notifier</string>
<key>CFBundleName</key><string>Squad Devkit</string>
<key>CFBundleDisplayName</key><string>Squad Devkit</string>
<key>CFBundleExecutable</key><string>squad-notifier</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Squad Notification</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>CFBundleTypeExtensions</key><array><string>squadnotify</string></array>
</dict></array>
</dict></plist>
PLIST
if command -v codesign >/dev/null 2>&1; then codesign --force --deep --sign - "$stage_app" >/dev/null 2>&1 || true; fi
if [[ -e "$app_path" || -L "$app_path" ]]; then
  backup="$stage/previous.app"
  mv "$app_path" "$backup"
fi
mv "$stage_app" "$app_path"
if [[ -n "$backup" ]]; then rm -rf "$backup"; fi
backup=""
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path" >/dev/null 2>&1 || true
(( quiet )) || printf 'squad-notifier: built %s\n' "$app_path"
