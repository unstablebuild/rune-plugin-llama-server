#!/usr/bin/env bash
# Verifies properties of the built release tarball. Run after `make`.
#
# Guards:
#   1. The tarball exists.
#   2. It contains the expected payload: ./bin/llama-server, ./config.yaml,
#      and the bundled llama.cpp license. On Linux the binary ships with its
#      runtime-loadable backend modules (ggml*.so) alongside it in ./bin.
#   3. No source leaks: no C/C++ sources and no llama.cpp/ source tree
#      accidentally staged into pkg/. The payload must be only the compiled
#      binary (plus backend modules), config.yaml, and license text.
set -euo pipefail

TAR="${TAR:-llama-server.tar.gz}"

if [ ! -f "$TAR" ]; then
	echo "error: $TAR not found; run 'make' first" >&2
	exit 1
fi

# List archive members. Matches the build's gtar invocation (entries are
# relative to pkg/, e.g. ./bin/llama-server).
members="$(tar -tzf "$TAR")"

for want in ./bin/llama-server ./config.yaml \
	./licenses/llama.cpp/LICENSE; do
	if ! printf '%s\n' "$members" | grep -qxF "$want"; then
		echo "error: $TAR is missing expected member '$want'" >&2
		printf 'members:\n%s\n' "$members" >&2
		exit 1
	fi
done
echo "ok: $TAR contains ./bin/llama-server, ./config.yaml, and llama.cpp license"

# On Linux the CPU backend ships as runtime-loadable modules next to the
# binary (GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS). Require at least one so a
# broken payload without any backend never ships. macOS embeds Metal in the
# binary and has no such modules.
if printf '%s\n' "$members" | grep -q '\.so$'; then
	if ! printf '%s\n' "$members" | grep -qE '^\./bin/libggml-cpu-.*\.so$'; then
		echo "error: $TAR ships .so modules but no ggml CPU backend module" >&2
		printf 'members:\n%s\n' "$members" >&2
		exit 1
	fi
	echo "ok: $TAR bundles ggml CPU backend modules"
fi

# No C/C++ sources should leak into the release.
src_files="$(printf '%s\n' "$members" | grep -E '\.(c|cc|cpp|cxx|h|hpp|cu|metal)$' || true)"
if [ -n "$src_files" ]; then
	echo "error: $TAR contains C/C++ source files:" >&2
	printf '%s\n' "$src_files" >&2
	exit 1
fi

# The llama.cpp source submodule must never be staged into pkg/. It would
# appear as a top-level ./llama.cpp/ tree; the bundled ./licenses/llama.cpp/
# notice is intentional and excluded.
src_leaks="$(printf '%s\n' "$members" | grep -E '^\./llama\.cpp/' || true)"
if [ -n "$src_leaks" ]; then
	echo "error: $TAR contains llama.cpp/ source tree:" >&2
	printf '%s\n' "$src_leaks" >&2
	exit 1
fi

echo "ok: no source leaks in $TAR"
