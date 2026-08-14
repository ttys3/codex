# Codex macOS arm64 cross-compile image

This private image uses Fedora 44 on Linux arm64 to build the unsigned Codex
macOS arm64 package. It follows the `https-killer-rs` setup by exposing
`oa64-clang`, `oa64-clang++`, and the target-specific `CC`, `CXX`, `AR`, Cargo
linker, and bindgen variables.

Fedora's native Clang 22, `ld64.lld`, and LLVM archive tools provide the
Mach-O toolchain. The image deliberately does not build osxcross's cctools or
apple-libtapi: the SDK is the only non-Fedora toolchain input, so building the
image does not compile Clang support libraries. Thin launchers give Clang the
macOS target, deployment target, SDK, and LLD settings and preserve the
osxcross command names used by the reference project.

The image build verifies C and libc++ links, archive tools, stripping, and
Mach-O arm64 output.

The Apple SDK must not be committed to this repository or published in a
public image. Build the image from a locally generated SDK tarball and keep the
GHCR package private:

```sh
podman build \
  --platform linux/arm64 \
  --build-context macos_sdk=/path/to/osxcross/tarballs \
  --file .github/docker/macos-cross/Dockerfile \
  --tag ghcr.io/ttys3/codex-macos-cross:macos-27.0 \
  .
```

The named context must contain `MacOSX27.0.sdk.tar.xz`. To verify the image:

```sh
podman run --rm --platform linux/arm64 \
  ghcr.io/ttys3/codex-macos-cross:macos-27.0 \
  bash -c 'oa64-clang -dumpmachine && clang --version && aarch64-apple-darwin-strip --version'
```

Log in with a token that has `write:packages`, push the image, and confirm that
the package is private. In the package's **Manage Actions access** settings,
grant `ttys3/codex` read access. The workflow pins the image digest, so update
that digest in `downstream-release.yml` whenever the image is rebuilt.
