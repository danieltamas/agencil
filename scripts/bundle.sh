#!/usr/bin/env bash
# Builds Agencil.app from the SwiftPM targets: the app binary, the CLI (Contents/Resources/agencil,
# which the installer copies out), Info.plist and the icons committed in Support. Ad hoc signed.
# --universal builds arm64 and x86_64 and joins them; --version and --build stamp Info.plist,
# --source the commit a build from a checkout comes from (AgencilSource, for Settings > About);
# --identity <name>|- picks the signing identity (default: "Agencil Local" when present, else ad hoc);
# --scratch and --out place the build. The source and build paths are remapped in the binaries,
# so where the tree lives leaves no trace in them. Prints the .app path on stdout.
set -euo pipefail
cd "$(dirname "$0")/.."

archs=("$(uname -m)")
version=""
build=""
source=""
release=0
scratch=.build
out=build
identity=""
while (($#)); do
  case $1 in
    --universal) archs=(arm64 x86_64) ;;
    --version) version=$2; shift ;;
    --build) build=$2; shift ;;
    --source) source=$2; shift ;;
    --release) release=1 ;;
    --scratch) scratch=$2; shift ;;
    --out) out=$2; shift ;;
    --identity) identity=$2; shift ;;
    *) echo "usage: bundle.sh [--universal] [--version <x.y.z> --build <n>] [--source <describe>] [--release] [--scratch <dir>] [--out <dir>] [--identity <name>|-]" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$scratch" "$out"
src=$(pwd -P)
scratch=$(cd "$scratch" && pwd -P)
export ZERO_AR_DATE=1

# The version is embedded in each binary (a section the linker reads as its Info.plist), so the CLI the
# installer copies out of the bundle can still answer `agencil version`.
embedded=$scratch/embedded-info.plist
cat > "$embedded" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ro.danieltamas.agencil</string>
<key>CFBundleShortVersionString</key><string>${version:-0.0.0}</string>
</dict></plist>
PLIST

slices=()
for arch in "${archs[@]}"; do
  flags=(-c release --scratch-path "$scratch" --triple "$arch-apple-macosx14.0"
         -Xswiftc -file-prefix-map -Xswiftc "$src=/agencil"
         -Xswiftc -file-prefix-map -Xswiftc "$scratch=/agencil/.build"
         -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$embedded"
         # Without module breadcrumbs the remapped build path is not looked up as a module cache (a wall of warnings).
         -Xswiftc -Xfrontend -Xswiftc -no-clang-module-breadcrumbs)
  swift build "${flags[@]}" >&2
  slices+=("$(swift build "${flags[@]}" --show-bin-path)")
done

app="$out/Agencil.app"
if [[ -d "$app" ]]; then rm -R "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Never `agencil` beside `Agencil`: they are one file on a case-insensitive disk. The CLI lives in
# Resources under its installed name, and is built as AgencilCLI for the same reason.
for binary in Agencil AgencilCLI; do
  if [[ $binary == Agencil ]]; then dest="$app/Contents/MacOS/Agencil"; else dest="$app/Contents/Resources/agencil"; fi
  lipo -create "${slices[@]/%//$binary}" -output "$dest"
  # SwiftPM adds the toolchain's own library folder as an rpath. Nothing loads from it (the
  # Swift runtime is the OS's), and it would tie the bytes to where Xcode is installed.
  otool -l "$dest" | awk '$1 == "path" { print $2 }' | sort -u \
    | { grep '\.xctoolchain/' || true; } | while read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$dest" 2>/dev/null
    done
  # Debug symbols name each object file with its build time; the release carries none.
  strip -S "$dest" 2>/dev/null
done
cp Support/Info.plist "$app/Contents/Info.plist"
if [[ -n $version ]]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${build:-1}" "$app/Contents/Info.plist"
fi
# A checkout without tags or without git still names where it came from.
[[ -n $source ]] || source=$(git describe --tags --always 2>/dev/null || echo unknown)
# A release build carries no source: About shows it as a release, not as a build from a checkout.
if ((!release)); then
  plutil -replace AgencilSource -string "$source" "$app/Contents/Info.plist"
fi
cp Support/AppIcon.icns Support/MenuBarIcon.pdf Support/mesh.png "$app/Contents/Resources/"
cp -R Support/MenuBarFrames Support/Vendors "$app/Contents/Resources/"
# Settings > More apps starts from this copy of the app registry (scripts/registry-snapshot.sh takes it).
cp -R Support/Registry "$app/Contents/Resources/"
# About's Update runs the same installer as the curl line, pinned to the release it showed.
install -m 755 install.sh "$app/Contents/Resources/install.sh"

# Ad-hoc unless this Mac has "Agencil Local" (scripts/make-signing-identity.sh): an ad-hoc build is a
# new app to macOS privacy every time. A release stays ad-hoc so two builds match byte for byte.
if [[ -z $identity ]]; then
  identity=-
  # Captured first: grep -q closing the pipe early would fail the pipeline under pipefail.
  identities=$(security find-identity -p codesigning 2>/dev/null || true)
  if [[ -z $version && $identities == *'"Agencil Local"'* ]]; then identity="Agencil Local"; fi
fi
codesign --force --sign "$identity" "$app/Contents/Resources/agencil"
codesign --force --sign "$identity" "$app"
echo "$app"
