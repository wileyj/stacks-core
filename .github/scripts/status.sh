#!/usr/bin/env bash
set -euo pipefail


# JOBS='{
#     "unit-tests": {
#     "result": "success",
#     "outputs": {}
#     },
#     "open-api-validation": {
#       "result": "success",
#       "outputs": {}
#     },
#     "node-config-docsgen": {
#       "result": "success",
#       "outputs": {}
#     },
#     "core-contracts-clarinet-test": {
#       "result": "success",
#       "outputs": {}
#     }
#   }'
# SUMMARY_PRINT=true
# echo "JOBS: $JOBS"
# echo $(echo "${JOBS}" | jq -r 'keys[]')
# exit

# Check the jobs status and print the failures
failing_jobs=()

echo "JOBS: $JOBS"
# Function to print output to GitHub Step Summary
print_to_step_summary() {
    echo "### Jobs Status" >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
    echo "Some jobs that are required to succeed have failed." >> "$GITHUB_STEP_SUMMARY"
}

# Check that 'jq' command exists
if ! command -v jq > /dev/null 2>&1; then
    echo "jq command doesn't exist!";
    exit 1;
fi

# Search for failures and append them to a list
for job_name in $(echo "${JOBS}" | jq -r 'keys[]'); do
    echo "job_name: $job_name"
    result=$(echo '${JOBS}' | jq -r ".[\"$job_name\"].result")
    if [[ "$result" != "success" ]]; then
        failing_jobs+=("$job_name")
    fi
done

# If there is no failing job, exit
if [[ ${#failing_jobs[@]} -eq 0 ]]; then
    echo "All jobs were successful!"
    exit 0
fi

# Print failing jobs to console
echo "Required jobs failed:"
for job in "${failing_jobs[@]}"; do
    echo "- $job"
done

# If the 'summary_print' input is true, print jobs to GitHub Step Summary, then fail the job
if [[ "${SUMMARY_PRINT}" == "true" ]]; then
    print_to_step_summary
fi
