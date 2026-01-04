#!/usr/bin/env bash
set -euo pipefail

# macOS equivalent of buildUnityDLL.bat; rebuilds dependencies with a static
# runtime and then builds the Unity dynamic library.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DUB_PKG_ROOT="${DUB_PKG_ROOT:-${HOME}/.dub/packages}"

resolve_ldc_bin() {
    if [[ -n "${LDC_BIN:-}" ]]; then
        echo "${LDC_BIN}"
        return
    fi

    if command -v ldc2 >/dev/null 2>&1; then
        dirname "$(command -v ldc2)"
        return
    fi

    if command -v brew >/dev/null 2>&1 && brew --prefix ldc >/dev/null 2>&1; then
        echo "$(brew --prefix ldc)/bin"
        return
    fi

    echo "/opt/homebrew/opt/ldc/bin"
}

LDC_BIN="$(resolve_ldc_bin)"
export PATH="${LDC_BIN}:${PATH}"
export DFLAGS="${DFLAGS:--link-defaultlib-shared=false --dllimport=none}"

# Ensure ldc2 finds the LLVM it was built against (Homebrew ldc depends on keg-only llvm@20).
if [[ -z "${DYLD_LIBRARY_PATH:-}" ]]; then
    if command -v brew >/dev/null 2>&1 && brew --prefix llvm@20 >/dev/null 2>&1; then
        export DYLD_LIBRARY_PATH="$(brew --prefix llvm@20)/lib"
    fi
fi

DUB="${DUB:-${LDC_BIN}/dub}"
if [[ ! -x "${DUB}" ]]; then
    if command -v dub >/dev/null 2>&1; then
        DUB="$(command -v dub)"
    else
        echo "dub not found; install LDC/dub or set DUB to the executable path." >&2
        exit 1
    fi
fi

build_dep() {
    local dep_path="${DUB_PKG_ROOT}/$1"
    if [[ ! -d "${dep_path}" ]]; then
        echo "Dependency path missing: ${dep_path}" >&2
        exit 1
    fi

    echo "=== Rebuilding $1 with static runtime ==="
    (cd "${dep_path}" && "${DUB}" build -q --compiler=ldc2 --force)
}

build_dep "mir-core/1.7.3/mir-core"
build_dep "mir-algorithm/3.22.4/mir-algorithm"
build_dep "imagefmt/2.1.2/imagefmt"
build_dep "fghj/1.0.2/fghj"
build_dep "inmath/1.0.6/inmath"

echo "=== Building nijilive-unity dynamic library ==="
cd "${PROJECT_ROOT}"
UNITY_CONFIG="${UNITY_CONFIG:-unity-dll-macos}"
"${DUB}" build -q -c "${UNITY_CONFIG}" --force

echo "Done."
