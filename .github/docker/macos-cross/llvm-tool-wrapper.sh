#!/bin/sh

set -eu

tool=${0##*/}
tool=${tool##*-}

case "${tool}" in
    ar | nm | objdump | ranlib | size | strings | strip)
        exec "/usr/bin/llvm-${tool}" "$@"
        ;;
    *)
        echo "unsupported LLVM tool alias: ${0##*/}" >&2
        exit 2
        ;;
esac
