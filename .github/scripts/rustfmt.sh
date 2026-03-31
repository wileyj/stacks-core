#!/usr/bin/env bash
set -euo pipefail

fmt_alias="${INPUT_ALIAS}"
fmt_manifest_path="${INPUT_MANIFEST_PATH}"

# Find Cargo config file
declare -a config_file_locations=(".cargo/config.toml" ".cargo/config")
config_file=""
for file in "${config_file_locations[@]}"; do
    if [ -f "$file" ]; then
    config_file="$file"
    break
    fi
done
if [ -z "$config_file" ]; then
    echo "No config file found!";
    exit 1;
fi

# Split alias command's options
alias=$(grep -e "${fmt_alias}.*=" "$config_file" | tr -d '"' | awk -v key="${fmt_alias}" '$0 ~ ("^" key "[[:space:]]*=") {sub(/^[^=]*=[[:space:]]*/,""); print; exit}')

before_empty_dashes=""
after_empty_dashes=""
reached_empty_dashes=false

IFS=' '

read -ra args <<< "$alias"

if [[ "${args[0]}" != "fmt" && "${fmt_alias}" != "fmt" ]]; then
    echo "The provided alias is invalid!";
    exit 1;
fi

for arg in "${args[@]}"; do
    if [[ "$arg" == "--" ]]; then
    reached_empty_dashes=true;
    continue;
    fi

    if $reached_empty_dashes; then
    after_empty_dashes="$after_empty_dashes $arg";
    else
    before_empty_dashes="$before_empty_dashes $arg";
    fi
done

# Run cargo and store the original output
CARGO_STATUS=0
CARGO_OUTPUT=$(cargo ${before_empty_dashes:-fmt} --all --manifest-path=${fmt_manifest_path} -- $after_empty_dashes --color=always --check 2>/dev/null) || CARGO_STATUS=$?

if [ ${CARGO_STATUS} -eq 0 ]; then
    cat <<MARKDOWN_INTRO >> $GITHUB_STEP_SUMMARY
# Rustfmt Results

The code is formatted correctly
MARKDOWN_INTRO
else
    cat <<MARKDOWN_INTRO >> $GITHUB_STEP_SUMMARY
# Rustfmt Results

\`cargo fmt\` reported formatting errors in the following locations.
You can fix them by executing the following command and committing the changes.
\`\`\`bash
cargo fmt --all
\`\`\`
MARKDOWN_INTRO

    echo "${CARGO_OUTPUT}" |
        # Strip color codes
        sed 's/\x1B\[[0-9;]*[A-Za-z]//g' |
        # Strip (some) cursor movements
        sed 's/\x1B.[A-G]//g' |
        tr "\n" "\r" |
        # Wrap each location into a HTML details
        sed -E 's#Diff in ([^\r]*?) at line ([[:digit:]]+):\r((:?[ +-][^\r]*\r)+)#<details>\n<summary>\1:\2</summary>\n\n```diff\n\3```\n\n</details>\n\n#g' |
        tr "\r" "\n" >> $GITHUB_STEP_SUMMARY
fi

# Print the original cargo message
echo "${CARGO_OUTPUT}"
# Exit with the same status as cargo
exit "${CARGO_STATUS}"
