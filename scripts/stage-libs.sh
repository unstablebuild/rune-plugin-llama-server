#!/usr/bin/env sh
# Stage llama-server and its runtime libraries into a destination bin/ as a
# SYMLINK-FREE payload.
#
# Why: the CMake build emits a versioned name chain per library, e.g.
#   macOS:  libllama.dylib -> libllama.0.dylib -> libllama.0.0.9158.dylib
#   Linux:  libggml.so     -> libggml.so.0     -> libggml.so.0.11.1
# where only the last entry is a real file and the rest are symlinks. Different
# loaders request different names in that chain:
#   * The executable and inter-library links resolve their dependency by the
#     recorded install-name / SONAME -- the MIDDLE name (e.g.
#     @rpath/libllama.0.dylib, DT_NEEDED libggml.so.0).
#   * ggml's dlopen backend loader enumerates modules by a bare ".so"
#     extension (ggml-backend-reg.cpp matches extension() == ".so"), i.e. the
#     UNVERSIONED name libggml-cpu-haswell.so.
# In every case the requested name exists in the build output only as a symlink.
#
# A prior "cp -P" staging preserved those symlinks, so the package worked only
# if every downstream copy also preserved symlinks. Package installers that
# flatten the payload into a bin/ directory without preserving symlinks kept
# just the fully-versioned real files, and the loader then failed with
# "Library not loaded: @rpath/libllama.0.dylib" / "cannot open shared object".
#
# To stay portable regardless of how the payload is later copied, we ship no
# symlinks at all: for each real library we materialize a REAL file under every
# name the build assigned it (the whole symlink chain), so whichever name a
# loader asks for resolves to a plain file.
#
# Usage: stage-libs.sh SRC_BIN_DIR DEST_BIN_DIR
set -eu

SRC="${1:?usage: stage-libs.sh SRC_BIN_DIR DEST_BIN_DIR}"
DEST="${2:?usage: stage-libs.sh SRC_BIN_DIR DEST_BIN_DIR}"
mkdir -p "$DEST"

os="$(uname | tr '[:upper:]' '[:lower:]')"
if [ "$os" = "darwin" ]; then
	pattern='*.dylib'
else
	pattern='*.so*'
fi

# resolve_basename follows a chain of same-directory symlinks and prints the
# basename of the final real file. Portable across BSD/macOS (no readlink -f).
resolve_basename() {
	dir="$(dirname "$1")"
	cur="$(basename "$1")"
	# Bound the walk; the build chains are at most a few links deep.
	i=0
	while [ -L "$dir/$cur" ] && [ "$i" -lt 16 ]; do
		cur="$(readlink "$dir/$cur")"
		cur="$(basename "$cur")"
		i=$((i + 1))
	done
	printf '%s\n' "$cur"
}

# The executable.
cp "$SRC/llama-server" "$DEST/llama-server"

# For each real library, materialize it under its own name and under every
# symlink name in SRC that resolves to it. Plain cp dereferences content; we
# never write a symlink into DEST.
found_lib=0
for lib in "$SRC"/$pattern; do
	[ -e "$lib" ] || continue   # no glob match
	[ -L "$lib" ] && continue   # aliases are handled from their real target
	found_lib=1
	real="$(basename "$lib")"
	cp "$lib" "$DEST/$real"
	for link in "$SRC"/$pattern; do
		[ -L "$link" ] || continue
		[ "$(resolve_basename "$link")" = "$real" ] || continue
		cp "$lib" "$DEST/$(basename "$link")"
	done
done

# macOS embeds Metal in the binary and ships no loadable backend modules, so
# "no libraries" is only an error on Linux.
if [ "$found_lib" -eq 0 ] && [ "$os" != "darwin" ]; then
	echo "stage-libs: no shared libraries found in $SRC" >&2
	exit 1
fi
