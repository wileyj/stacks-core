#!/usr/bin/env bash
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
## Outputs written to $GITHUB_OUTPUT for subsequent steps:
##   target       - Rust target triple (e.g. x86_64-unknown-linux-gnu)
##   zipfile_name - Base archive filename without extension (e.g. linux-glibc-x64)
##
set -euo pipefail

## ── ANSI color codes and logging helpers ─────────────────────────────────────
## Convention: ALL_CAPS for env var inputs and exported/GitHub values;
##             lowercase for all script-local variables.
COLRED=$'\033[31m'    ## Red
COLGREEN=$'\033[32m'  ## Green
COLYELLOW=$'\033[33m' ## Yellow
COLRESET=$'\033[0m'   ## Reset color/formatting

strip_ansi() { printf '%s' "$*" | sed $'s/\033\\[[0-9;]*m//g'; }
info()  { echo "${COLGREEN}INFO:${COLRESET}    $*"; }
warn()  { echo "${COLYELLOW}WARN:${COLRESET}    $*"; }
error() { echo "${COLRED}ERROR:${COLRESET}   $*" >&2; echo "**ERROR:** $(strip_ansi "$*")" >> "${GITHUB_STEP_SUMMARY}"; }
hl()    { printf '%s' "${COLYELLOW}$*${COLRESET}"; }  ## highlight an inline value

## ── Validate required inputs ──────────────────────────────────────────────────
## Uppercase: env var inputs supplied by the calling workflow step.
: "${MATRIX_CPU:?MATRIX_CPU is required}"
: "${MATRIX_ARCH:?MATRIX_ARCH is required}"
: "${CMD:?CMD is required}"
SIGNER_ONLY="${SIGNER_ONLY:-false}"

## ── Preserve cargo color output in CI (cargo disables color when stdout is not a TTY)
export CARGO_TERM_COLOR=always

## ── Determine which binaries to build ────────────────────────────────────────
## Lowercase: script-local variables derived within this script.
bins=""
if [[ "${SIGNER_ONLY}" == "true" ]]; then
    bins="--bin stacks-signer"
fi

## ── Initialise per-target variables ──────────────────────────────────────────
target=""
target_cpu=""
linker=""
archive_name=""

## ── Configure target platform ────────────────────────────────────────────────
case "${MATRIX_CPU}" in
    x86-64*)
        # Derive archive suffix: x86-64 → x64, x86-64-v3 → x64-v3, etc.
        archive_name="$(echo "${MATRIX_CPU}" | sed -e 's|86-||g')"
        # Default generic x86-64 to -v3; honour explicit versioned variants as-is
        case "${MATRIX_CPU}" in
            x86-64) target_cpu="${MATRIX_CPU}-v3" ;;
            *)       target_cpu="${MATRIX_CPU}"    ;;
        esac

        case "${MATRIX_ARCH}" in
            linux-glibc)
                info "Installing dependencies for $(hl "linux-glibc x86_64") build"
                sudo apt-get update && sudo apt-get install -y git libclang-dev llvm
                target="x86_64-unknown-linux-gnu"
                ;;
            linux-musl)
                info "Installing dependencies for $(hl "linux-musl x86_64") build"
                sudo apt-get update && sudo apt-get install -y musl-tools
                target="x86_64-unknown-linux-musl"
                ;;
            windows)
                info "Installing dependencies for $(hl "windows x86_64") build"
                sudo apt-get update && sudo apt-get install -y git gcc-mingw-w64-x86-64
                target="x86_64-pc-windows-gnu"
                linker="x86_64-w64-mingw32-gcc"
                ;;
            *)
                error "Unsupported arch $(hl "${MATRIX_ARCH}") for cpu $(hl "${MATRIX_CPU}")"
                exit 1
                ;;
        esac
        ;;

    arm64)
        archive_name="${MATRIX_CPU}"

        case "${MATRIX_ARCH}" in
            linux-glibc)
                info "Installing dependencies for $(hl "linux-glibc arm64") build"
                sudo apt-get update && sudo apt-get install -y git gcc-aarch64-linux-gnu libclang-dev llvm
                target="aarch64-unknown-linux-gnu"
                linker="aarch64-linux-gnu-gcc"
                ;;
            linux-musl)
                info "Installing dependencies for $(hl "linux-musl arm64") build"
                sudo apt-get update && sudo apt-get install -y gcc-aarch64-linux-gnu musl-dev
                # musl.cc has aggressive rate limits from Azure IPs; use the GitHub mirror instead
                curl -LSf -# \
                    https://github.com/musl-cc/musl.cc/releases/download/v0.0.1/aarch64-linux-musl-cross.tgz \
                    | tar zxf - -C /tmp
                target="aarch64-unknown-linux-musl"
                linker="/tmp/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc"
                ;;
            macos)
                info "Installing dependencies for $(hl "macOS arm64") build"
                # macOS arm64 — no extra deps, use native CPU tuning
                target="aarch64-apple-darwin"
                target_cpu="native"
                ;;
            *)
                error "Unsupported arch $(hl "${MATRIX_ARCH}") for cpu $(hl "${MATRIX_CPU}")"
                exit 1
                ;;
        esac
        ;;

    *)
        error "Unsupported cpu $(hl "${MATRIX_CPU}")"
        exit 1
        ;;
esac

if [[ -z "${target}" ]]; then
    error "target is empty for $(hl "${MATRIX_ARCH}-${MATRIX_CPU}")"
    exit 1
fi

zipfile_name="${MATRIX_ARCH}-${archive_name}"

## ── Write outputs for subsequent workflow steps ───────────────────────────────
{
    echo "target=${target}"
    echo "zipfile_name=${zipfile_name}"
} >> "${GITHUB_OUTPUT}"

## ── Install Rust toolchain and add the cross-compilation target ──────────────
rust_toolchain="$(cat ./rust-toolchain)"
rustup toolchain install "${rust_toolchain}" --no-self-update || {
    error "Failed to install Rust toolchain $(hl "${rust_toolchain}")"
    exit 1
}
rustup target add "${target}" --toolchain "${rust_toolchain}" || {
    error "Failed to add target $(hl "${target}") to toolchain $(hl "${rust_toolchain}")"
    exit 1
}

## ── Build ────────────────────────────────────────────────────────────────────
# CMD and bins are intentionally unquoted so the shell performs word-splitting
# on the multi-word command/flag strings.
# shellcheck disable=SC2086
case "${target}" in
    # linux-glibc aarch64 — requires an explicit cross-linker
    aarch64-unknown-linux-gnu)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config \"target.${target}.linker=\\\"${linker}\\\"\""
        ${CMD} ${bins} --target "${target}" --config "target.${target}.linker=\"${linker}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # linux-glibc x86_64 — use the default linker, tune CPU
    x86_64-unknown-linux-gnu)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config build.rustflags=\"\\\"-C target-cpu=${target_cpu}\\\"\""
        ${CMD} ${bins} --target "${target}" --config build.rustflags="\"-C target-cpu=${target_cpu}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # windows x86_64 — MinGW cross-linker + CPU tuning
    x86_64-pc-windows-gnu)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config \"target.${target}.linker=\\\"${linker}\\\"\" --config build.rustflags=\"\\\"-C target-cpu=${target_cpu}\\\"\""
        ${CMD} ${bins} --target "${target}" --config "target.${target}.linker=\"${linker}\"" --config build.rustflags="\"-C target-cpu=${target_cpu}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # linux-musl x86_64 — static musl, CPU tuning
    x86_64-unknown-linux-musl)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config build.rustflags=\"\\\"-C target-cpu=${target_cpu}\\\"\""
        ${CMD} ${bins} --target "${target}" --config build.rustflags="\"-C target-cpu=${target_cpu}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # linux-musl aarch64 — musl cross-linker
    aarch64-unknown-linux-musl)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config \"target.${target}.linker=\\\"${linker}\\\"\""
        ${CMD} ${bins} --target "${target}" --config "target.${target}.linker=\"${linker}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # macOS aarch64 — native CPU tuning, no cross-linker needed
    aarch64-apple-darwin)
        info "Building $(hl "${target}"): ${CMD} ${bins} --target ${target} --config build.rustflags=\"\\\"-C target-cpu=${target_cpu}\\\"\""
        ${CMD} ${bins} --target "${target}" --config build.rustflags="\"-C target-cpu=${target_cpu}\"" || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;

    # Catch-all: run the default command if no target triple matched
    *)
        warn "No explicit configuration for target $(hl "${target}"). Using defaults."
        ${CMD} ${bins} || {
            error "Build failed for target $(hl "${target}")"
            exit 1
        }
        ;;
esac
