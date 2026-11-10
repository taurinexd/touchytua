#!/bin/sh
# Builds universal (arm64 + x86_64) release binaries into plugin/bin/.
set -eu
cd "$(dirname "$0")/../mac"
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build-$arch" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
done
mkdir -p ../plugin/bin
for b in touchytua touchytuad touchytua-hook touchytua-statusline; do
  lipo -create ".build-arm64/release/$b" ".build-x86_64/release/$b" -output "../plugin/bin/$b"
  strip -S -x "../plugin/bin/$b"
  codesign --force --sign - "../plugin/bin/$b"
done
ls -la ../plugin/bin
