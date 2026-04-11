#!/usr/bin/env bash
##
## Checks whether the current branch name matches a release pattern and, if so,
## derives the release tags and validates them against versions.toml.
##
## Required env vars (set by the calling workflow step):
##   BRANCH  - branch name from github.ref_name (e.g. release/1.0.0.0.0)
##
## Outputs written to $GITHUB_OUTPUT for subsequent steps/jobs:
##   node_tag          - node release tag       (e.g. 1.0.0.0.0)         empty for signer-only releases
##   node_docker_tag   - node docker tag        (e.g. 1.0.0.0.0)         empty for signer-only releases
##   signer_tag        - signer release tag     (e.g. signer-1.0.0.0.0.0)
##   signer_docker_tag - signer docker tag      (e.g. 1.0.0.0.0.0)
##   is_node_release   - "true" if this is a node release branch
##   is_signer_release - "true" if this is a signer release branch
##
## Exit behaviour:
##   - Branch matches a release pattern  → validates versions.toml, writes outputs, exits 0
##   - Branch does not match             → exits 0 (all outputs empty/false; downstream
##                                         jobs guard themselves with is_node/signer_release checks)
##   - Validation error                  → writes error to $GITHUB_STEP_SUMMARY, exits 1
##
set -euo pipefail

## ── ANSI color codes and logging helpers ─────────────────────────────────────
## Convention: ALL_CAPS for env var inputs and GitHub runner values;
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
## Uppercase: env var input supplied by the calling workflow step.
: "${BRANCH:?BRANCH is required}"

## ── Release branch patterns ───────────────────────────────────────────────────
## Lowercase: script-local constants derived and used only within this script.
## Node release:   release/[0-9].[0-9].[0-9].[0-9].[0-9]   (5-part version, optional -rcN suffix)
## Signer release: release/signer-[0-9].[0-9].[0-9].[0-9].[0-9].[0-9]  (6-part version, optional -rcN suffix)
versions_file="versions.toml"
node_key="stacks_node_version"
signer_key="stacks_signer_version"

node_version_regex="([0-9]+\.){4}[0-9]+(-rc[0-9]+)?"
signer_version_regex="([0-9]+\.){5}[0-9]+(-rc[0-9]+)?"

release_prefix="release/"
signer_prefix="release/signer-"

node_release_regex="^${release_prefix}${node_version_regex}$"
signer_release_regex="^${signer_prefix}${signer_version_regex}$"

## ── Initialise output variables ───────────────────────────────────────────────
node_tag=""
node_docker_tag=""
signer_tag=""
signer_docker_tag=""
is_node_release=false
is_signer_release=false

## ── Match branch against release patterns ────────────────────────────────────
## Signer must be tested first — its prefix (release/signer-) is a superset of
## the node prefix (release/), so a signer branch would also match the node regex.
if [[ "${BRANCH}" =~ ${signer_release_regex} ]]; then
    signer_tag=$(echo "${BRANCH}"        | sed "s|^${release_prefix}||")
    signer_docker_tag=$(echo "${BRANCH}" | sed "s|^${signer_prefix}||")
    is_signer_release=true
elif [[ "${BRANCH}" =~ ${node_release_regex} ]]; then
    node_tag=$(echo "${BRANCH}"          | sed "s|^${release_prefix}||")
    node_docker_tag="${node_tag}"
    ## Derive the signer tag by appending an extra .0 version component
    signer_tag="signer-$(echo "${node_tag}" | sed 's/\(-[^-]*\)*$/.0\1/')"
    signer_docker_tag=$(echo "${node_tag}"  | sed 's/\(-[^-]*\)*$/.0\1/')
    is_node_release=true
    is_signer_release=true
else
    ## Not a release branch — write empty/false outputs and exit cleanly so that
    ## downstream jobs can evaluate their own is_node/signer_release conditions.
    warn "Branch $(hl "${BRANCH}") does not match a release pattern. Skipping."
    {
        echo "node_tag="
        echo "node_docker_tag="
        echo "signer_tag="
        echo "signer_docker_tag="
        echo "is_node_release=false"
        echo "is_signer_release=false"
    } >> "${GITHUB_OUTPUT}"
    exit 0
fi

## ── Validate versions.toml ────────────────────────────────────────────────────
if [[ ! -f "${versions_file}" ]]; then
    error "$(hl "${versions_file}") not found"
    exit 1
fi

node_version=$(grep   "^${node_key}"   "${versions_file}" | sed -E 's/.*=\s*"([^"]+)"/\1/')
signer_version=$(grep "^${signer_key}" "${versions_file}" | sed -E 's/.*=\s*"([^"]+)"/\1/')

if [[ -z "${node_version}" ]]; then
    error "$(hl "${node_key}") not found in $(hl "${versions_file}")"
    exit 1
fi

if [[ -z "${signer_version}" ]]; then
    error "$(hl "${signer_key}") not found in $(hl "${versions_file}")"
    exit 1
fi

if [[ "${is_node_release}" == "true" && "${node_version}" != "${node_docker_tag}" ]]; then
    error "node version in $(hl "${versions_file}") ($(hl "${node_version}")) does not match branch tag ($(hl "${node_docker_tag}"))"
    exit 1
fi

if [[ "${signer_version}" != "${signer_docker_tag}" ]]; then
    error "signer version in $(hl "${versions_file}") ($(hl "${signer_version}")) does not match branch tag ($(hl "${signer_docker_tag}"))"
    exit 1
fi

info "Node version:   $(hl "${node_version}")"
info "Signer version: $(hl "${signer_version}")"

## ── Write outputs ─────────────────────────────────────────────────────────────
{
    echo "node_tag=${node_tag}"
    echo "node_docker_tag=${node_docker_tag}"
    echo "signer_tag=${signer_tag}"
    echo "signer_docker_tag=${signer_docker_tag}"
    echo "is_node_release=${is_node_release}"
    echo "is_signer_release=${is_signer_release}"
} >> "${GITHUB_OUTPUT}"
