#!/bin/sh
# Rebuild libjxllama.dylib — the in-process llama.cpp engine.
#
# Requires the llama.cpp static libraries already built at
#   <tree>/build-jxrouter
# (cmake with GGML_METAL=ON and GGML_METAL_EMBED_LIBRARY=ON so the Metal
# shaders are baked into libggml-metal.a and no external .metallib is needed).
#
# WHICH TREE — this matters more than anything else here.
# The default is the Prism fork, ~/.prism/llama.cpp
# (github.com/PrismML-Eng/llama.cpp, branch "prism"), because it adds
# GGML_TYPE_PQ2_0 (142) / PTQ1_0 (143) and the prism.hadamard.* rotated-basis
# transform carried by Ternary-Bonsai / Bonsai 2 GGUFs. A stock upstream tree
# rejects those files outright ("invalid ggml type 142"), and an engine built
# from it cannot load them at all. That failure is invisible at build time and
# only surfaces later as "the app does not detect my model", so this script
# prefers the fork and warns loudly if the result lacks the formats.
# Falls back to ~/.unsloth/llama.cpp when the fork is not checked out.
#
#   ./build.sh                                      # auto (fork if present)
#   LLAMA_SRC=$HOME/.unsloth/llama.cpp ./build.sh   # explicit tree
#   JX_ENGINE_STOCK=1 ./build.sh                    # force stock upstream
#
# The result is arm64-only. That is intentional: the app stays universal and
# loads this dylib with dlopen, so Intel Macs simply fall back to the
# llama-server subprocess.
set -eu

if [ -z "${LLAMA_SRC:-}" ]; then
    if [ "${JX_ENGINE_STOCK:-0}" != "1" ] && [ -d "$HOME/.prism/llama.cpp" ]; then
        LLAMA_SRC="$HOME/.prism/llama.cpp"
    else
        LLAMA_SRC="$HOME/.unsloth/llama.cpp"
    fi
fi
BUILD="${LLAMA_BUILD:-$LLAMA_SRC/build-jxrouter}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$BUILD/src/libllama.a" ]; then
    echo "error: $BUILD/src/libllama.a not found. Build llama.cpp first." >&2
    exit 1
fi

echo "==> compiling jx_llama_bridge.cpp"
clang++ -std=c++17 -arch arm64 -O2 -dynamiclib \
    -install_name @rpath/libjxllama.dylib \
    -I"$LLAMA_SRC/include" -I"$LLAMA_SRC/ggml/include" \
    "$HERE/jx_llama_bridge.cpp" \
    -L"$BUILD/src" \
    -L"$BUILD/ggml/src" \
    -L"$BUILD/ggml/src/ggml-metal" \
    -L"$BUILD/ggml/src/ggml-blas" \
    -L"$BUILD/tools/mtmd" \
    -L"$BUILD/vendor/hash" \
    -lllama -lmtmd -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lvendor-hash \
    -framework Metal -framework MetalKit -framework Accelerate -framework Foundation \
    -o "$HERE/libjxllama.dylib"

echo "==> signing"
codesign --force --sign - "$HERE/libjxllama.dylib"

# Prove the engine carries the ternary formats before anyone ships it. An
# engine without them still builds and still passes every other check, which is
# exactly how a stock engine reached /Applications unnoticed.
PQ2_COUNT=$(grep -a -c PQ2_0 "$HERE/libjxllama.dylib" 2>/dev/null || true)
case "$PQ2_COUNT" in ''|*[!0-9]*) PQ2_COUNT=0 ;; esac
echo "==> quant-format coverage"
if [ "$PQ2_COUNT" -gt 0 ]; then
    echo "    PQ2_0/PTQ1_0 present — ternary Bonsai GGUFs are loadable"
else
    echo "    WARNING: this engine has NO PQ2_0/PTQ1_0 support." >&2
    echo "             Ternary-Bonsai / Bonsai 2 GGUFs will fail to load." >&2
    echo "             Rebuild against the Prism fork:" >&2
    echo "               LLAMA_SRC=\$HOME/.prism/llama.cpp $0" >&2
fi

echo "==> done"
lipo -info "$HERE/libjxllama.dylib"
ls -lh "$HERE/libjxllama.dylib"
