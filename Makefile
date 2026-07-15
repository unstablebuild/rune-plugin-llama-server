SRC=llama.cpp
TAR=llama-server.tar.gz

# Build model: same-OS, cross-arch (mirrors rune-plugin-rg). macOS hosts build
# both darwin arches natively; Linux hosts build both linux arches inside an
# Ubuntu container matching upstream llama.cpp's release toolchain. Only
# TARGET_ARCH may differ from the host; TARGET_OS is always the host OS.
HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

# GNU tar: named `gtar` on macOS (Homebrew coreutils), plain `tar` on Linux.
# The --no-xattrs/--no-acls flags below are GNU extensions, so BSD tar won't do.
ifeq ($(HOST_OS),darwin)
GTAR ?= gtar
else
GTAR ?= tar
endif

# CMake / compiler knobs.
CMAKE ?= cmake
JOBS ?= $(shell (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4))

# LINUX_BUILD_IMAGE is the container used to build the Linux artifacts. It
# mirrors upstream llama.cpp's release pipeline (ubuntu-22.04 / ubuntu-24.04),
# which sets the effective glibc floor of the published binary. We do NOT try
# to lower that floor: modern llama.cpp requires a recent compiler to build its
# CPU/SIMD kernels, and this is a standalone, optional package. Users on older
# distros who cannot meet the floor compile llama-server themselves and point
# Rune at it via `models.local.server_bin_path`.
LINUX_BUILD_IMAGE ?= ubuntu:22.04

# Base CMake flags shared by every OS/arch. This matches upstream llama.cpp's
# release build: build the server tool, keep a portable CPU baseline
# (GGML_NATIVE=OFF), and ship the CPU backend as runtime-loadable modules
# (GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS) so one package runs across CPU
# generations. A relative rpath (set per-OS below) lets the binary find its
# sibling backend modules.
CMAKE_FLAGS := \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_WEBUI=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_LLGUIDANCE=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=ON \
  -DGGML_CPU_ALL_VARIANTS=ON \
  -DGGML_BUILD_TESTS=OFF \
  -DGGML_BUILD_EXAMPLES=OFF

# On macOS enable the Metal backend (embedded shader library) and Accelerate
# BLAS so the shipped binary can offload to the GPU. Metal is a single-arch
# per-slice backend, so the runtime-loadable CPU variants above do not apply.
ifeq ($(HOST_OS),darwin)
  CMAKE_FLAGS := $(filter-out -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON,$(CMAKE_FLAGS))
  # macOS resolves sibling libraries relative to the loading binary via
  # @loader_path (the Mach-O analogue of ELF's $ORIGIN).
  CMAKE_FLAGS += -DCMAKE_INSTALL_RPATH=@loader_path
  CMAKE_FLAGS += -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON
  OSX_ARCH_amd64=x86_64
  OSX_ARCH_arm64=arm64
  CMAKE_FLAGS += -DCMAKE_OSX_ARCHITECTURES=$(OSX_ARCH_$(TARGET_ARCH))
  # Pin the deployment floor so the embedded .metallib and C/C++ objects target
  # a tested minimum macOS rather than the build host's SDK.
  DARWIN_MIN_MACOS ?= 13.3
  CMAKE_FLAGS += -DCMAKE_OSX_DEPLOYMENT_TARGET=$(DARWIN_MIN_MACOS)
  CMAKE_FLAGS += -DGGML_METAL_MACOSX_VERSION_MIN=$(DARWIN_MIN_MACOS)
else
  # ELF resolves sibling libraries relative to the binary via $ORIGIN.
  CMAKE_FLAGS += -DCMAKE_INSTALL_RPATH=$$ORIGIN
endif

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

.PHONY: $(DIST_TARGETS) clean test stage build-native build-linux-docker
default: $(TAR)

# stage compiles llama-server for the target OS/arch and stages the binary +
# its runtime-loadable backend modules + config.yaml + license under pkg/. It
# is phony so the config/license copy always runs even when the binary is
# already built (an incremental rebuild must never produce a tarball missing
# config.yaml or the license). Linux builds are delegated to an Ubuntu
# container matching upstream; darwin builds run natively on the host
# toolchain.
stage:
	# Start from a clean bin/ so artifacts from a prior build (e.g. a
	# different OS/arch, or Linux .so modules) never leak into this payload.
	rm -rf pkg/bin
	@mkdir -p pkg/bin pkg/licenses/llama.cpp
ifeq ($(HOST_OS),linux)
	$(MAKE) build-linux-docker TARGET_ARCH=$(TARGET_ARCH)
else
	$(MAKE) build-native TARGET_ARCH=$(TARGET_ARCH)
endif
	chmod +x pkg/bin/llama-server
	cp config.yaml pkg
	# Bundle llama.cpp's license so the redistributed binary carries the
	# notice its MIT license requires.
	cp llama.cpp/LICENSE pkg/licenses/llama.cpp/LICENSE

# build-native configures and builds llama-server directly on the host (used
# for darwin, and as the in-container step for linux). The binary and its
# sibling backend modules (ggml*.so / libggml*.so on Linux) are staged
# together so the $ORIGIN rpath resolves them at runtime.
build-native:
	@mkdir -p pkg/bin
	$(CMAKE) -S $(SRC) -B $(SRC)/_build $(CMAKE_FLAGS)
	$(CMAKE) --build $(SRC)/_build --target llama-server -j $(JOBS)
	find $(SRC)/_build/bin -maxdepth 1 \
		\( -name 'llama-server' -o -name '*.so*' -o -name '*.dylib' \) \
		-exec cp -P {} pkg/bin/ \;

# build-linux-docker builds llama-server for TARGET_ARCH inside an Ubuntu
# image matching upstream llama.cpp's release toolchain (see LINUX_BUILD_IMAGE).
# buildx provides the target-arch base image; the binary plus its backend .so
# modules are exported together.
build-linux-docker:
	@mkdir -p pkg/bin
	docker buildx build \
		--platform linux/$(TARGET_ARCH) \
		--build-arg BASE_IMAGE=$(LINUX_BUILD_IMAGE) \
		--build-arg JOBS=$(JOBS) \
		-f deploy/Dockerfile.linux \
		--output type=local,dest=pkg/bin \
		.

$(TAR): stage
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Verify release-tarball properties (no source leaks, expected payload).
test: $(TAR)
	TAR=$(TAR) ./scripts/test.sh

$(DIST_TARGETS): dist-%:
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) $(TAR) TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

clean:
	rm -rf $(TAR)
	rm -rf pkg/
	rm -rf $(SRC)/_build
