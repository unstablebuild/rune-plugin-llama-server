# llama-server for Rune

A Rune package that bundles
[`llama-server`](https://github.com/ggml-org/llama.cpp), the
OpenAI-compatible inference server from llama.cpp, and makes it available to
Rune's local-model support.

## What it installs

Installing this package:

- Adds the `llama-server` executable to your Rune data directory so the
  editor can launch it on demand when you run a local GGUF model. Rune
  resolves the binary automatically through the package manager — there is
  no separate setup step.

When you select a local model, Rune starts `llama-server` as a managed
subprocess, waits for it to become ready, and talks to it over its
OpenAI-compatible HTTP API. The server is shut down automatically after an
idle period.

## Install

Open the [Rune console](https://docs.rune.build/learn/console) and run:

```
pkg install llama-server
```

The console is the read-evaluate-print loop where you install packages and
manage Rune. Open it from the command prompt by running `console`, then type
the command above. Local models start using `llama-server` right away.

To learn more about how packages and extensions are delivered and
configured, see the [Extensions guide](https://docs.rune.build/develop/extensions).

## Building from source

This repository builds the release package from llama.cpp's source, pinned
as a git submodule.

```
git clone --recurse-submodules <this-repo>
make
```

`make` compiles `llama-server` for the host operating system and current
architecture, stages it alongside `config.yaml` under `pkg/`, and produces
the release tarball `llama-server.tar.gz`. To build for the other
architecture of the same operating system:

```
make TARGET_ARCH=arm64   # or amd64
```

### Linux builds

Linux builds run inside an Ubuntu container via `docker buildx`, matching
upstream llama.cpp's own release toolchain (Ubuntu 22.04 / GCC). This sets the
glibc floor of the published binary (Ubuntu 22.04 ⇒ **glibc ≥ 2.35**). We do
not lower that floor: modern llama.cpp needs a recent compiler to build its
CPU/SIMD kernels. The base image is configurable:

```
make LINUX_BUILD_IMAGE=ubuntu:22.04   # default
```

The CPU backend is built as several runtime-loadable modules (`ggml*.so`, one
per microarchitecture) via `GGML_BACKEND_DL` + `GGML_CPU_ALL_VARIANTS`, exactly
like upstream; ggml selects the best module for the host CPU at load time. The
binary and its sibling `.so` modules ship together under `bin/` and share an
`$ORIGIN` rpath.

Hosts that cannot meet the glibc floor should compile `llama-server`
themselves and point Rune at it with `models.local.server_bin_path`.

macOS builds run natively and enable the Metal GPU backend with the embedded
shader library, pinned to a `13.3` deployment floor.

`make test` verifies the release tarball contains the expected payload and
no source leaks.

## License

This repository's packaging (the Makefile, Dockerfile, scripts, and
configuration) is licensed under the MIT License; see [LICENSE](./LICENSE).

The bundled `llama-server` binary is built from
[llama.cpp](https://github.com/ggml-org/llama.cpp), distributed under the
MIT License. Its license text ships inside the release package under
`licenses/llama.cpp/`. Rune's local inference depends on the llama.cpp /
GGML kernels, GGUF ecosystem, samplers, and chat templating — with thanks to
Georgi Gerganov and the llama.cpp / GGML contributors.
