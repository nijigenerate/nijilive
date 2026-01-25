#!/usr/bin/env bash
# Build nijilive-unity.dylib on macOS using LDC (mirrors windows/buildUnityDLL.bat)
set -euo pipefail

# Change these if you have LDC in a different location.
LDC_ROOT="${LDC_ROOT:-/opt/ldc}"
LDC_BIN="${LDC_BIN:-${LDC_ROOT}/bin}"
DUB="${DUB:-${LDC_BIN}/dub}"
CONFIG="${CONFIG:-unity-dll-macos}"

# Flags to mimic static runtime and no default imports, same as Windows script intent.
DFLAGS="-link-defaultlib-shared=false --dllimport=none"

echo "=== Rebuilding dependencies with static runtime ==="
(
  cd "${HOME}/.dub/packages/mir-core/1.7.3/mir-core" && "${DUB}" build -q --compiler=ldc2 --force
)
(
  cd "${HOME}/.dub/packages/mir-algorithm/3.22.4/mir-algorithm" && "${DUB}" build -q --compiler=ldc2 --force
)
(
  cd "${HOME}/.dub/packages/fghj/1.0.2/fghj" && "${DUB}" build -q --compiler=ldc2 --force
)
(
  cd "${HOME}/.dub/packages/inmath/1.0.6/inmath" && "${DUB}" build -q --compiler=ldc2 --force
)

echo "=== Building nijilive-unity.dylib ==="
DFLAGS="${DFLAGS}" "${DUB}" build -q --config "${CONFIG}" --compiler="${LDC_BIN}/ldc2"

echo "Done."
