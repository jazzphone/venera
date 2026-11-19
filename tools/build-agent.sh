#!/bin/bash
# build-agent: build/venera-agent and build/venera-clipboard (x86_64, macOS 26), Venera's guest agent and clipboard
# agent (agent/venera-agent.m, agent/venera-clipboard.m), ad-hoc signed.
# agent/test-agent.py checks its protocol (build it for the Mac you test on: ARCH=arm64 tools/build-agent.sh; MINOS=15.0
# for an older macOS than 26).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
mkdir -p build
xcrun clang -arch "${ARCH:-x86_64}" -mmacosx-version-min=${MINOS:-26.0} -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
  -fmodules -framework Foundation -framework OpenDirectory -framework IOKit -DVENERA_VERSION="\"$VERSION\"" -o build/venera-agent agent/venera-agent.m
xcrun clang -arch "${ARCH:-x86_64}" -mmacosx-version-min=${MINOS:-26.0} -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
  -fmodules -framework AppKit -framework IOKit -DVENERA_VERSION="\"$VERSION\"" -o build/venera-clipboard agent/venera-clipboard.m
codesign -s - --force --timestamp=none build/venera-agent >/dev/null 2>&1
codesign -s - --force --timestamp=none build/venera-clipboard >/dev/null 2>&1
echo "build/venera-agent, build/venera-clipboard ($VERSION)"
