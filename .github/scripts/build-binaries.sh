#!/usr/bin/env bash
set -euo pipefail

##
## Build release binaries for a given target platform.
##
## Required env vars (set by the calling workflow step):
##   MATRIX_CPU   - CPU target from the build matrix  (e.g. x86-64, arm64)
##   MATRIX_ARCH  - OS/ABI target from the build matrix (e.g. linux-glibc, linux-musl, macos, windows)
##   CMD          - Full cargo build command string
##
## Optional env vars:
##   SIGNER_ONLY  - "true" to build only stacks-signer; defaults to "false" (build all)
##
## Outputs written to $GITHUB_ENV for subsequent steps:
##   TARGET       - Rust target triple (e.g. x86_64-unknown-linux-gnu)
##   TARGET_CPU   - Rust/LLVM CPU name (e.g. x86-64-v3, native)
##   ZIPFILE_NAME - Base archive filename without extension (e.g. linux-glibc-x64)
##

## ── Validate required inputs ─────────────────────────────────────────────────
: "${MATRIX_CPU:?MATRIX_CPU is required}"
: "${MATRIX_ARCH:?MATRIX_ARCH is required}"
: "${CMD:?CMD is required}"
SIGNER_ONLY="${SIGNER_ONLY:-false}"

## ── Preserve cargo color output in CI (cargo disables color when stdout is not a TTY)
export CARGO_TERM_COLOR=always
## ansi color codes for terminal output
COLRED=$'\033[31m'    ## Red
COLGREEN=$'\033[32m'  ## Green
COLYELLOW=$'\033[33m' ## Yellow
COLRESET=$'\033[0m'   ## reset color/formatting

## ── Determine which binaries to build ────────────────────────────────────────
BINS=""
if [[ "${SIGNER_ONLY}" == "true" ]]; then
    BINS="--bin stacks-signer"
fi

## ── Initialize per-target variables ──────────────────────────────────────────
TARGET=""
TARGET_CPU=""
LINKER=""
ARCHIVE_NAME=""

## ── Configure target platform ────────────────────────────────────────────────
case "${MATRIX_CPU}" in
    x86-64*)
        # Derive archive suffix: x86-64 → x64, x86-64-v3 → x64-v3, etc.
        # shellcheck disable=SC2001
        ARCHIVE_NAME="$(echo "${MATRIX_CPU}" | sed -e 's|86-||g')"
        # Default generic x86-64 to -v3; honor explicit versioned variants as-is
        case "${MATRIX_CPU}" in
            x86-64) TARGET_CPU="${MATRIX_CPU}-v3" ;;
            *) TARGET_CPU="${MATRIX_CPU}"    ;;
        esac

        case "${MATRIX_ARCH}" in
            linux-glibc)
                echo "${COLGREEN}Installing dependencies for linux-glibc x86_64 build${COLRESET}"
                sudo apt-get update && sudo apt-get install -y git libclang-dev llvm
                TARGET="x86_64-unknown-linux-gnu"
                ;;
            linux-musl)
                echo "${COLGREEN}Installing dependencies for linux-musl x86_64 build${COLRESET}"
                sudo apt-get update && sudo apt-get install -y musl-tools
                TARGET="x86_64-unknown-linux-musl"
                ;;
            windows)
                echo "${COLGREEN}Installing dependencies for windows x86_64 build${COLRESET}"
                sudo apt-get update && sudo apt-get install -y git gcc-mingw-w64-x86-64
                TARGET="x86_64-pc-windows-gnu"
                LINKER="x86_64-w64-mingw32-gcc"
                ;;
            *)
                echo "${COLRED}ERROR: Unsupported arch '${MATRIX_ARCH}' for cpu '${MATRIX_CPU}'${COLRESET}"
                exit 1
                ;;
        esac
        ;;

    arm64)
        ARCHIVE_NAME="${MATRIX_CPU}"

        case "${MATRIX_ARCH}" in
            linux-glibc)
                echo "${COLGREEN}Installing dependencies for linux-glibc arm64 build${COLRESET}"
                sudo apt-get update && sudo apt-get install -y git gcc-aarch64-linux-gnu libclang-dev llvm
                TARGET="aarch64-unknown-linux-gnu"
                LINKER="aarch64-linux-gnu-gcc"
                ;;
            linux-musl)
                echo "${COLGREEN}Installing dependencies for linux-musl arm64 build${COLRESET}"
                sudo apt-get update && sudo apt-get install -y gcc-aarch64-linux-gnu musl-dev
                # musl.cc has aggressive rate limits from Azure IPs; use the GitHub mirror instead
                curl -LSf -# \
                    https://github.com/musl-cc/musl.cc/releases/download/v0.0.1/aarch64-linux-musl-cross.tgz \
                    | tar zxf - -C /tmp
                TARGET="aarch64-unknown-linux-musl"
                LINKER="/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc"
                ;;
            macos)
                echo "${COLGREEN}Installing dependencies for macOS arm64 build${COLRESET}"
                # macOS arm64 — no extra deps, use native CPU tuning
                TARGET="aarch64-apple-darwin"
                TARGET_CPU="native"
                ;;
            *)
                echo "${COLRED}ERROR:${COLRESET} Unsupported arch '${MATRIX_ARCH}' for cpu '${MATRIX_CPU}'"
                exit 1
                ;;
        esac
        ;;

    *)
        echo "${COLRED}ERROR:${COLRESET} Unsupported cpu '${MATRIX_CPU}'"
        exit 1
        ;;
esac

if [[ -z "${TARGET}" ]]; then
    echo "${COLRED}ERROR: TARGET is empty for ${MATRIX_ARCH}-${MATRIX_CPU}${COLRESET}"
    exit 1
fi

ZIPFILE_NAME="${MATRIX_ARCH}-${ARCHIVE_NAME}"

## ── Export env vars for subsequent workflow steps ────────────────────────────
# shellcheck disable=SC2129
echo "TARGET=${TARGET}" >> "${GITHUB_ENV}"
echo "TARGET_CPU=${TARGET_CPU}" >> "${GITHUB_ENV}"
echo "ZIPFILE_NAME=${ZIPFILE_NAME}" >> "${GITHUB_ENV}"

## ── Install Rust toolchain and add the cross-compilation target ──────────────
RUST_TOOLCHAIN="$(cat ./rust-toolchain)"
rustup toolchain install "${RUST_TOOLCHAIN}" --no-self-update || {
    echo "${COLRED}Error installing Rust toolchain ${RUST_TOOLCHAIN}${COLRESET}"
    exit 1
}
rustup target add "${TARGET}" --toolchain "${RUST_TOOLCHAIN}" || {
    echo "${COLRED}Error adding target ${TARGET} to Rust toolchain ${RUST_TOOLCHAIN}${COLRESET}"
    exit 1
}

## ── Build ────────────────────────────────────────────────────────────────────
# CMD and BINS are intentionally unquoted so the shell performs word-splitting
# on the multi-word command/flag strings.
# shellcheck disable=SC2086
case "${TARGET}" in
    # linux-glibc aarch64 — requires an explicit cross-linker
    aarch64-unknown-linux-gnu)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config \"target.${TARGET}.linker=\\\"${LINKER}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config "target.${TARGET}.linker=\"${LINKER}\"" || exit 1
        ;;

    # linux-glibc x86_64 — use the default linker, tune CPU
    x86_64-unknown-linux-gnu)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config build.rustflags=\"\\\"-C target-cpu=${TARGET_CPU}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config build.rustflags="\"-C target-cpu=${TARGET_CPU}\"" || exit 1
        ;;

    # windows x86_64 — MinGW cross-linker + CPU tuning
    x86_64-pc-windows-gnu)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config \"target.${TARGET}.linker=\\\"${LINKER}\\\"\" --config build.rustflags=\"\\\"-C target-cpu=${TARGET_CPU}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config "target.${TARGET}.linker=\"${LINKER}\"" --config build.rustflags="\"-C target-cpu=${TARGET_CPU}\"" || exit 1
        ;;

    # linux-musl x86_64 — static musl, CPU tuning
    x86_64-unknown-linux-musl)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config build.rustflags=\"\\\"-C target-cpu=${TARGET_CPU}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config build.rustflags="\"-C target-cpu=${TARGET_CPU}\"" || exit 1
        ;;

    # linux-musl aarch64 — musl cross-linker
    aarch64-unknown-linux-musl)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config \"target.${TARGET}.linker=\\\"${LINKER}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config "target.${TARGET}.linker=\"${LINKER}\"" || exit 1
        ;;

    # macOS aarch64 — native CPU tuning, no cross-linker needed
    aarch64-apple-darwin)
        echo "${COLGREEN}Running:${COLRESET} ${CMD} ${BINS} --target ${TARGET} --config build.rustflags=\"\\\"-C target-cpu=${TARGET_CPU}\\\"\""
        ${CMD} ${BINS} --target "${TARGET}" --config build.rustflags="\"-C target-cpu=${TARGET_CPU}\"" || exit 1
        ;;

    # Catch-all: run the default command if no target triple matched
    *)
        echo "${COLYELLOW}No explicit configuration for target '${TARGET}'. Using defaults.${COLRESET}"
        ${CMD} ${BINS} || exit 1
        ;;
esac
exit 0
