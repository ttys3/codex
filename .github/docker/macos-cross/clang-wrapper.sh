#!/bin/sh

set -eu

sdkroot=${SDKROOT:-/opt/macos-sdk/MacOSX.sdk}
deployment_target=${MACOSX_DEPLOYMENT_TARGET:-11.0}
linker_flag=-fuse-ld=lld

for argument in "$@"; do
    case "${argument}" in
        -c | -E | -M | -MM | -S | --analyze | -fsyntax-only)
            linker_flag=
            ;;
    esac
done

if [ -n "${linker_flag}" ]; then
    set -- "${linker_flag}" "$@"
fi

case "${0##*/}" in
    *++ | *c++)
        compiler=/usr/bin/clang++
        set -- -stdlib=libc++ "$@"
        ;;
    *)
        compiler=/usr/bin/clang
        ;;
esac

exec "${compiler}" \
    --target=arm64-apple-darwin \
    "-mmacosx-version-min=${deployment_target}" \
    -isysroot "${sdkroot}" \
    "$@"
