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

Linux builds run inside an NVIDIA CUDA **devel** container via `docker buildx`
so the package ships GPU support; a GPU is not needed at build time, only
nvcc. The image is Ubuntu 22.04-based, matching upstream llama.cpp's release
toolchain, which sets the glibc floor of the published binary (Ubuntu 22.04 ⇒
**glibc ≥ 2.35**). We do not lower that floor: modern llama.cpp needs a recent
compiler to build its CPU/SIMD kernels. The image and CUDA settings are
configurable:

```
make CUDA_VERSION=12.8.1 UBUNTU_VERSION=22.04   # defaults
make CUDA_ARCHITECTURES=default                 # portable PTX list (default)
make LINUX_BUILD_IMAGE=nvidia/cuda:12.8.1-devel-ubuntu22.04  # or override outright
```

Backends are built as runtime-loadable modules via `GGML_BACKEND_DL`:
`GGML_CPU_ALL_VARIANTS` emits one `ggml-cpu-<arch>.so` per microarchitecture,
and `GGML_CUDA=ON` adds `libggml-cuda.so`. At load time ggml enumerates the
sibling `ggml-*.so` modules and selects the best backend for the host — the
CUDA module when an NVIDIA GPU and driver are present, otherwise the
best-matching CPU module — so one package runs on both GPU and CPU-only hosts.
The binary and its sibling `.so` modules ship together under `bin/` and share
an `$ORIGIN` rpath.

The NVIDIA CUDA runtime libraries are **not** bundled: doing so would grow the
package by ~1GB and pull NVIDIA's CUDA EULA into an otherwise MIT-only
package. GPU offload therefore requires the host to provide, in addition to
the NVIDIA driver (`libcuda.so.1`), a CUDA 12 runtime (`libcudart.so.12`,
`libcublas.so.12`, `libcublasLt.so.12`) — e.g. the distro's
`nvidia-cuda-toolkit` runtime packages. Hosts without them simply run on the
CPU backend; ggml skips the CUDA module when its dependencies are absent. The
C++ runtime is linked statically into the binary and every module
(`-static-libstdc++`/`-static-libgcc`, including `CMAKE_MODULE_LINKER_FLAGS`
for the dlopen'd backend modules), so no host libstdc++ newer than the glibc
floor is required. Because nvcc cannot run under QEMU, Linux CUDA builds must
run on native hardware for the target arch; cross-arch Linux builds are
rejected.

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
