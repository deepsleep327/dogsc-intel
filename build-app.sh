#!/bin/bash
# Build a complete, locally signed development app from this checkout.
set -euo pipefail

cd "$(dirname "$0")"
project_root="$PWD"
app_output="$project_root/.build/local/DogSC Dev.app"
signing_identity="${DOGSC_SIGNING_IDENTITY:-}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Intel/x86_64 support: DogSC builds natively for any macOS host
# architecture. `swift build` targets the host architecture by default, so the
# same script produces arm64 on Apple Silicon and x86_64 on Intel.
host_arch="$(uname -m)"

# Extra flags for `swift build` (e.g. --disable-sandbox in restricted shells).
build_flags="${DOGSC_SWIFT_BUILD_FLAGS:-}"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "DogSC requires macOS with Xcode 26+." >&2
  exit 1
fi

# Signing: with DOGSC_SIGNING_IDENTITY unset or "-", fall back to an ad-hoc
# signature so the app can still be built and launched locally.
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  sign_mode=adhoc
  sign_args=(--sign -)
else
  sign_mode=identity
  sign_args=(--sign "$signing_identity")
  if [[ ! "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "Set DOGSC_SIGNING_IDENTITY to your Apple Development certificate's SHA-1 fingerprint." >&2
    echo "List available identities with: security find-identity -v -p codesigning" >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning | grep -F "$signing_identity" >/dev/null; then
    echo "The specified signing identity is not available in your keychain." >&2
    exit 1
  fi
fi
echo "Building DogSC for $host_arch (signing: $sign_mode)"
if [[ -e "$app_output" ]] && pgrep -x DogSC >/dev/null; then
  echo "Save your work and quit DogSC before replacing an existing development app." >&2
  exit 1
fi

swift build -c release --product DogSC $build_flags
binary_dir="$(swift build -c release --show-bin-path)"
sparkle_source="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -f "$binary_dir/DogSC" && -d "$sparkle_source" ]]

# Stage inside the build directory so the final move never crosses volumes
# (`mv` between /var/folders and an external volume fails with EXDEV).
mkdir -p "$project_root/.build/staging"
staging_dir="$(mktemp -d "$project_root/.build/staging/dogsc-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/DogSC Dev.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$binary_dir/DogSC" "$app/Contents/MacOS/DogSC"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName DogSC Dev' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName DogSC Dev' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cn.laogou.dogsc.dev' "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
for resource in en.lproj zh-Hans.lproj Fonts Onboarding Support; do
  ditto "Resources/$resource" "$app/Contents/Resources/$resource"
  diff -qr "Resources/$resource" "$app/Contents/Resources/$resource"
done
# InfoPlist.strings takes precedence over Info.plist, including in permission
# prompts. Check every locale so a release-name override cannot hide "Dev".
for localized_info in "$app/Contents/Resources/"*.lproj/InfoPlist.strings; do
  [[ -f "$localized_info" ]] || continue
  plutil -lint "$localized_info" >/dev/null
  for identity_key in CFBundleName CFBundleDisplayName CFBundleIdentifier; do
    expected_identity="$(/usr/libexec/PlistBuddy -c "Print :$identity_key" "$app/Contents/Info.plist")"
    if localized_identity="$(plutil -extract "$identity_key" raw -o - "$localized_info" 2>/dev/null)"; then
      if [[ "$localized_identity" != "$expected_identity" ]]; then
        echo "Localized $identity_key overrides the development identity in $localized_info." >&2
        exit 1
      fi
    fi
  done
done
(cd "$app/Contents/Resources/Fonts" && shasum -a 256 -c SHA256SUMS)
ditto "$sparkle_source" "$app/Contents/Frameworks/Sparkle.framework"

framework="$app/Contents/Frameworks/Sparkle.framework"
framework_version="$framework/Versions/B"
codesign --force --options runtime "${sign_args[@]}" \
  "$framework_version/XPCServices/Installer.xpc"
codesign --force --options runtime --preserve-metadata=entitlements "${sign_args[@]}" \
  "$framework_version/XPCServices/Downloader.xpc"
for component in "$framework_version/Autoupdate" "$framework_version/Updater.app" "$framework"; do
  codesign --force --options runtime "${sign_args[@]}" "$component"
done
codesign --force --options runtime --entitlements Resources/DogSC.entitlements \
  "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"

signature_details="$(codesign -dvvv "$app" 2>&1)"
if [[ "$sign_mode" = identity ]]; then
  grep -F 'Authority=Apple Development:' <<< "$signature_details" >/dev/null
fi
# Ad-hoc signatures report 0x10002(adhoc,runtime) instead of 0x10000(runtime).
grep -E 'flags=0x[0-9a-f]+\((adhoc,)?runtime\)' <<< "$signature_details" >/dev/null
[[ "$(lipo -archs "$app/Contents/MacOS/DogSC")" = "$host_arch" ]]
otool -l "$app/Contents/MacOS/DogSC" | grep -F '@executable_path/../Frameworks' >/dev/null

# Check again after the build; never remove a bundle used by a running app.
if [[ -e "$app_output" ]] && pgrep -x DogSC >/dev/null; then
  echo "DogSC is running. Quit it and run this command again to install the new build." >&2
  exit 1
fi
mkdir -p "$(dirname "$app_output")"
if [[ -e "$app_output" ]]; then
  mv "$app_output" "$staging_dir/previous.app"
fi
if ! mv "$app" "$app_output"; then
  if [[ -d "$staging_dir/previous.app" ]]; then
    mv "$staging_dir/previous.app" "$app_output"
  fi
  exit 1
fi
printf 'Built: %s\n' "$app_output"
