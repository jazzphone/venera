#!/bin/bash
# build-agent: build/venera-agent (x86_64, macOS 26), Venera's guest agent (agent/venera-agent.m), ad-hoc signed.
# agent/test-agent.py checks its protocol (build it for the Mac you test on: ARCH=arm64 tools/build-agent.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
mkdir -p build
xcrun clang -arch "${ARCH:-x86_64}" -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
  -fmodules -framework Foundation -framework OpenDirectory -framework IOKit -DVENERA_VERSION="\"$VERSION\"" -o build/venera-agent agent/venera-agent.m
codesign -s - --force --timestamp=none build/venera-agent >/dev/null 2>&1
echo "build/venera-agent ($VERSION)"
