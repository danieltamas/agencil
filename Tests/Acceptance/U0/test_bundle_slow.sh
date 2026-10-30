#!/usr/bin/env bash
# SLOW: builds the debug products and a real signed release bundle.
source "$(dirname "$0")/helpers.bash"
macos
workspace
require_file Package.swift
swift build
require_exec .build/debug/Agencil
require_exec .build/debug/AgencilCLI
bundle
require_exec "$APP/Contents/MacOS/Agencil"
require_exec "$APP/Contents/Resources/agencil"
# Directory entries, not -e: on a case-insensitive disk Agencil also matches agencil.
if find "$APP/Contents/MacOS" -maxdepth 1 -name agencil | grep -q .; then
  fail 'CLI is in Contents/MacOS/agencil'
fi
plist=$APP/Contents/Info.plist
[[ $(defaults read "$plist" CFBundleIdentifier) == ro.danieltamas.agencil ]] || fail 'bundle identifier'
[[ $(defaults read "$plist" LSUIElement) == 1 ]] || fail 'LSUIElement is not true'
[[ $(defaults read "$plist" LSMinimumSystemVersion) == 14.0 ]] || fail 'minimum macOS is not 14.0'
[[ -n $(defaults read "$plist" AgencilSource) ]] || fail 'AgencilSource missing or empty'
codesign --verify --strict "$APP/Contents/Resources/agencil"
codesign --verify --strict --deep "$APP"
