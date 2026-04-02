#!/usr/bin/env bash
set -euo pipefail

# Validate JOBS is parseable JSON before doing anything else
if ! jq -e type <<< "${JOBS}" > /dev/null 2>&1; then
    echo "Error: JOBS is not valid JSON. Received: ${JOBS}"
    exit 1
fi

# Function to print output to GitHub Step Summary
print_to_step_summary() {
    echo "### Jobs Status" >> "$GITHUB_STEP_SUMMARY"
    echo "" >> "$GITHUB_STEP_SUMMARY"
    echo "Some jobs that are required to succeed have failed." >> "$GITHUB_STEP_SUMMARY"
}

# Check that 'jq' command exists
if ! command -v jq > /dev/null 2>&1; then
    echo "jq command doesn't exist"
    exit 1
fi

# Collect all jobs whose result is not "success" in a single jq pass
failing_jobs=()
while IFS= read -r job_name; do
    [[ -n "$job_name" ]] && failing_jobs+=("$job_name")
done < <(jq -r 'to_entries[] | select(.value.result != "success") | .key' <<< "${JOBS}")

# If there are no failing jobs, exit
if [[ ${#failing_jobs[@]} -eq 0 ]]; then
    echo "All jobs were successful"
    exit 0
fi

# Print failing jobs to console
if [ ${#failing_jobs[@]} -gt 0 ]; then
    echo "Required jobs failed:"
    for job in "${failing_jobs[@]}"; do
        echo "$job"
    done
fi

# If the 'summary_print' input is true, print to GitHub Step Summary, then fail
if [[ "${SUMMARY_PRINT}" == "true" ]]; then
    print_to_step_summary
fi
exit 1
