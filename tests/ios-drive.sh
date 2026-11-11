#!/bin/sh
# Drives the app in the Simulator with the scripted finger (ios/UITests).
# Usage: tests/ios-drive.sh "<steps>" [shot-dir]      steps: see DriverTests.swift
# Needs: a booted simulator named in $SIM (udid), and `xcodebuild build-for-testing` done.
set -eu
cd "$(dirname "$0")/../ios"
: "${SIM:?set SIM to the simulator udid}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEST_RUNNER_STEPS="$1" TEST_RUNNER_SHOT_DIR="${2:-/tmp}" \
  xcodebuild -project Touchytua.xcodeproj -scheme Touchytua -sdk iphonesimulator \
  -destination "id=$SIM" -derivedDataPath .build test-without-building \
  -only-testing:TouchytuaUITests/DriverTests/testDrive 2>&1 \
  | grep -E "error:|XCTAssert|never |no element|unknown step|DRIVER|\*\* TEST" || true
