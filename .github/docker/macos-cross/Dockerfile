# syntax=docker/dockerfile:1.7

# Build this image only for linux/arm64. The macOS SDK comes from the named
# `macos_sdk` build context so it never enters this repository.
ARG MACOS_SDK_TARBALL=MacOSX27.0.sdk.tar.xz

FROM fedora:44 AS sdk

ARG MACOS_SDK_TARBALL

RUN dnf install -y --setopt=install_weak_deps=False \
        tar \
        xz \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=macos_sdk /${MACOS_SDK_TARBALL} /tmp/${MACOS_SDK_TARBALL}

RUN install -d /opt/macos-sdk \
    && tar -xf "/tmp/${MACOS_SDK_TARBALL}" -C /opt/macos-sdk \
    && test -d /opt/macos-sdk/MacOSX27.0.sdk \
    && ln -s MacOSX27.0.sdk /opt/macos-sdk/MacOSX.sdk \
    && rm "/tmp/${MACOS_SDK_TARBALL}"

FROM fedora:44

LABEL org.opencontainers.image.source="https://github.com/ttys3/codex" \
      org.opencontainers.image.description="Fedora 44 Linux arm64 toolbox for cross-compiling Codex to macOS arm64"

RUN dnf install -y --setopt=install_weak_deps=False \
        bzip2-devel \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        gcc \
        gcc-c++ \
        git \
        gzip \
        libuuid-devel \
        libxml2-devel \
        lld \
        llvm \
        make \
        ninja-build \
        openssl-devel \
        patch \
        perl \
        pkgconf-pkg-config \
        python3 \
        tar \
        xz \
        xz-devel \
        zlib-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=sdk /opt/macos-sdk /opt/macos-sdk
COPY --chmod=0755 .github/docker/macos-cross/clang-wrapper.sh /usr/local/bin/macos-clang-wrapper
COPY --chmod=0755 .github/docker/macos-cross/llvm-tool-wrapper.sh /usr/local/bin/macos-llvm-tool-wrapper

ENV SDKROOT="/opt/macos-sdk/MacOSX.sdk" \
    MACOSX_DEPLOYMENT_TARGET="11.0" \
    CC_aarch64_apple_darwin="oa64-clang" \
    CXX_aarch64_apple_darwin="oa64-clang++" \
    AR_aarch64_apple_darwin="aarch64-apple-darwin-ar" \
    RANLIB_aarch64_apple_darwin="aarch64-apple-darwin-ranlib" \
    CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="oa64-clang" \
    BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_darwin="--target=arm64-apple-darwin --sysroot=/opt/macos-sdk/MacOSX.sdk"

RUN set -eux; \
    test "$(uname -m)" = aarch64; \
    test "$(clang -dumpversion | cut -d. -f1)" -eq 22; \
    for compiler in \
        oa64-clang \
        oa64-clang++ \
        aarch64-apple-darwin-clang \
        aarch64-apple-darwin-clang++; \
    do \
        ln -s macos-clang-wrapper "/usr/local/bin/${compiler}"; \
    done; \
    for tool in ar nm objdump ranlib size strings strip; \
    do \
        ln -s macos-llvm-tool-wrapper "/usr/local/bin/aarch64-apple-darwin-${tool}"; \
    done; \
    test "$(oa64-clang -dumpmachine)" = arm64-apple-darwin; \
    test -d "${SDKROOT}"; \
    aarch64-apple-darwin-ar --version | grep -Fq 'LLVM version 22.'; \
    printf 'int main(void) { return 0; }\n' > /tmp/test.c; \
    printf '#include <iostream>\nint main() { std::cout << 42; }\n' > /tmp/test.cpp; \
    oa64-clang -O2 -Wall /tmp/test.c -o /tmp/test-c; \
    oa64-clang++ -O2 -Wall /tmp/test.cpp -o /tmp/test-cxx; \
    file /tmp/test-c /tmp/test-cxx | grep -Ec 'Mach-O 64-bit.*arm64' | grep -qx 2; \
    aarch64-apple-darwin-strip -x /tmp/test-cxx; \
    file /tmp/test-cxx | grep -Eq 'Mach-O 64-bit.*arm64'; \
    oa64-clang -c /tmp/test.c -o /tmp/test.o; \
    aarch64-apple-darwin-ar crs /tmp/libtest.a /tmp/test.o; \
    aarch64-apple-darwin-ar t /tmp/libtest.a | grep -Fxq test.o; \
    rm /tmp/libtest.a /tmp/test.c /tmp/test.cpp /tmp/test-c /tmp/test-cxx /tmp/test.o

WORKDIR /workspace

CMD ["/bin/bash"]
