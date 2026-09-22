#!/bin/sh
# Rebuild libjxllama.dylib — the in-process llama.cpp engine.
#
# Requires the llama.cpp static libraries already built at
#   ~/.unsloth/llama.cpp/build-jxrouter
# (cmake with GGML_METAL=ON and GGML_METAL_EMBED_LIBRARY=ON so the Metal
# shaders are baked into libggml-metal.a and no external .metallib is needed).
#
# The result is arm64-only. That is intentional: the app stays universal and
# loads this dylib with dlopen, so Intel Macs simply fall back to the
# llama-server subprocess.
set -eu

LLAMA_SRC="${LLAMA_SRC:-$HOME/.unsloth/llama.cpp}"
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

echo "==> done"
lipo -info "$HERE/libjxllama.dylib"
ls -lh "$HERE/libjxllama.dylib"
