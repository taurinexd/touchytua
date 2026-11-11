#!/bin/sh
# Drives the app with the scripted finger (ios/UITests), in the Simulator or
# on a real iPhone.
# Usage: tests/ios-drive.sh "<steps>" [shot-dir]      steps: see DriverTests.swift
# Needs `xcodebuild build-for-testing` done for the same destination, and
#   SIM=<udid>      a booted simulator, or
#   DEVICE=<udid>   a paired, unlocked iPhone (built into ios/.build/device).
#                   `shot` cannot write to the Mac from there: use
#                   `xcrun devicectl device capture screenshot` instead.
set -eu
cd "$(dirname "$0")/../ios"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ -n "${DEVICE:-}" ]; then
  set -- "$1" "${2:-/tmp}" -destination "id=$DEVICE" -derivedDataPath .build/device
else
  : "${SIM:?set SIM to a simulator udid, or DEVICE to an iPhone udid}"
  set -- "$1" "${2:-/tmp}" -sdk iphonesimulator -destination "id=$SIM" -derivedDataPath .build
fi
steps=$1 shots=$2
shift 2
TEST_RUNNER_STEPS="$steps" TEST_RUNNER_SHOT_DIR="$shots" \
  xcodebuild -project Touchytua.xcodeproj -scheme Touchytua "$@" test-without-building \
  -only-testing:TouchytuaUITests/DriverTests/testDrive 2>&1 \
  | grep -E "error:|XCTAssert|never |no element|unknown step|DRIVER|\*\* TEST" || true
