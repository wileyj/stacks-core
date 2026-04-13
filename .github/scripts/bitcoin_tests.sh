#!/usr/bin/env bash
set -euo pipefail

##
## Generate a balanced test matrix for the Bitcoin integration test workflow.
##
## Discovers all ignored tests in the stacks-node binary via cargo nextest,
## removes a hardcoded exclude list, then splits the remaining tests into
## MATRIX balanced partitions and writes each one to $GITHUB_OUTPUT.
##
## Required env vars:
##   GITHUB_OUTPUT  - Path to the GitHub Actions output file (set by runner)
##
## Optional env vars:
##   MATRIX         - Number of partitions to split tests into (default: 2)
##   MAX_PER_MATRIX - Maximum tests allowed per partition (default: 256)
##

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
hl()    { printf '%s' "${COLYELLOW}$*${COLRESET}"; }

## ── Configuration ────────────────────────────────────────────────────────────
matrix="${MATRIX:-2}"
max_per_matrix="${MAX_PER_MATRIX:-256}"

if ! [[ "$matrix" =~ ^[1-9][0-9]*$ ]]; then
    error "MATRIX must be a positive integer, got: ${matrix}"
    exit 1
fi

## ── Step 1: List all ignored tests via nextest ───────────────────────────────
info "Listing ignored tests from nextest archive..."
cargo nextest list --archive-file ~/test_archive.tar.zst -Tjson > nextest_output.json || {
    error "Error listing tests in $(hl ~/test_archive.tar.zst)"
    exit 1
}

jq -c '
    .["rust-suites"]["stacks-node::bin/stacks-node"]["testcases"]
    | [to_entries[] | select(.value.ignored) | .key]
' nextest_output.json > ignored_tests.json

info "Ignored tests count: $(hl $(jq 'length' ignored_tests.json))"

## ── Step 2: Build exclude list ───────────────────────────────────────────────
## Tests listed here are excluded from CI runs. Some of these may be
## worth investigating adding back into CI in the future.
info "Building exclude list..."
cat << 'EOF' > raw_exclude.txt
# The following tests are excluded from CI runs. Some of these may be worth investigating adding back into the CI
tests::nakamoto_integrations::consensus_hash_event_dispatcher
tests::neon_integrations::atlas_integration_test
tests::neon_integrations::atlas_stress_integration_test
tests::neon_integrations::bitcoind_resubmission_test
tests::neon_integrations::block_replay_integration_test
tests::neon_integrations::deep_contract
tests::neon_integrations::filter_txs_by_origin
tests::neon_integrations::filter_txs_by_type
tests::neon_integrations::lockup_integration
tests::neon_integrations::most_recent_utxo_integration_test
tests::neon_integrations::run_with_custom_wallet
tests::neon_integrations::test_competing_miners_build_anchor_blocks_on_same_chain_without_rbf
tests::neon_integrations::test_one_miner_build_anchor_blocks_on_same_chain_without_rbf
tests::signer::v0::tenure_extend::tenure_extend_after_2_bad_commits
tests::stackerdb::test_stackerdb_event_observer
tests::stackerdb::test_stackerdb_load_store
# Epoch tests are covered by the epoch-tests CI workflow, and don't need to run on every PR (for older epochs)
tests::epoch_205::test_cost_limit_switch_version205
tests::epoch_205::test_dynamic_db_method_costs
tests::epoch_205::test_exact_block_costs
tests::epoch_205::transition_empty_blocks
tests::epoch_21::test_sortition_divergence_pre_21
tests::epoch_21::test_v1_unlock_height_with_current_stackers
tests::epoch_21::test_v1_unlock_height_with_delay_and_current_stackers
tests::epoch_21::trait_invocation_cross_epoch
tests::epoch_21::transition_adds_burn_block_height
tests::epoch_21::transition_adds_get_pox_addr_recipients
tests::epoch_21::transition_adds_mining_from_segwit
tests::epoch_21::transition_adds_pay_to_alt_recipient_contract
tests::epoch_21::transition_adds_pay_to_alt_recipient_principal
tests::epoch_21::transition_empty_blocks
tests::epoch_21::transition_fixes_bitcoin_rigidity
tests::epoch_21::transition_removes_pox_sunset
tests::epoch_22::disable_pox
tests::epoch_22::pox_2_unlock_all
tests::epoch_23::trait_invocation_behavior
tests::epoch_24::fix_to_pox_contract
tests::epoch_24::verify_auto_unlock_behavior
# Disable this flaky test. We don't need continue testing Epoch 2 -> 3 transition
tests::nakamoto_integrations::flash_blocks_on_epoch_3_FLAKY
# These mempool tests take a long time to run, and are meant to be run manually
tests::nakamoto_integrations::large_mempool_original_constant_fee
tests::nakamoto_integrations::large_mempool_original_random_fee
tests::nakamoto_integrations::large_mempool_next_constant_fee
tests::nakamoto_integrations::large_mempool_next_random_fee
tests::nakamoto_integrations::larger_mempool
tests::nakamoto_integrations::check_block_info_rewards
tests::signer::v0::larger_mempool
EOF

## Strip blank lines and comments, then convert to JSON array
grep -v '^\s*$' raw_exclude.txt | grep -v '^\s*#' > clean_exclude.txt
jq -R . clean_exclude.txt | jq -s . > exclude.json
info "Excluded tests count: $(hl $(jq length exclude.json))"

## ── Step 3: Filter out excluded tests ────────────────────────────────────────
info "Filtering excluded tests..."
jq -e 'type == "array"' ignored_tests.json > /dev/null
jq -e 'type == "array"' exclude.json > /dev/null

jq -r '.[]' ignored_tests.json | sort > ignored_sorted.txt
jq -r '.[]' exclude.json       | sort > exclude_sorted.txt

comm -23 ignored_sorted.txt exclude_sorted.txt > filtered.txt

total=$(wc -l < filtered.txt)
info "Final test count: $(hl ${total})"

## ── Step 4: Validate capacity ────────────────────────────────────────────────
max_total=$(( matrix * max_per_matrix ))
if (( total > max_total )); then
    error "${total} tests exceed the limit of ${max_total} (${matrix} partitions × ${max_per_matrix} tests each)"
    error "Increase MATRIX or MAX_PER_MATRIX to accommodate."
    exit 1
fi

## ── Step 5: Split into N balanced partitions ─────────────────────────────────
info "Splitting $(hl ${total}) tests into $(hl ${matrix}) active partitions..."
mapfile -t tests < filtered.txt

base=$(( total / matrix ))
remainder=$(( total % matrix ))
offset=0

for (( i = 1; i <= matrix; i++ )); do
    ## Distribute remainder one test at a time across the first partitions
    size=$(( base + ( i <= remainder ? 1 : 0 ) ))
    partition=$(printf '%s\n' "${tests[@]:$offset:$size}" | jq -R . | jq -s -c .)
    info "matrix${i}: $(hl ${size}) tests"
    echo "matrix${i}=${partition}" >> "${GITHUB_OUTPUT}"
    offset=$(( offset + size ))
done
