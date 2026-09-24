#!/usr/bin/env bash
#
# Regression tests for the commenter's handlers/utilities.
#
# 1. Runs test_comment_utility.sh - fast unit tests for the curl-based
#    GitHub API calls (posting, listing/paginating, deleting PR comments)
#    with a faked `curl` so no network calls are made.
# 2. For every fixture in test_files.sh, regenerates a PR comment payload
#    from the raw CLI output in testing/gitactions_output/ and diffs it
#    against the golden/expected payload checked in under
#    testing/pr_payload/. This guards against regressions in the
#    handlers/utilities that build comment bodies.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GOLDEN_DIR="$ROOT_DIR/testing/pr_payload"
INPUT_DIR="$ROOT_DIR/testing/gitactions_output"
ACTUAL_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$ACTUAL_DIR"
}
trap cleanup EXIT

# shellcheck source=testing/scripts/test_files.sh
source "$SCRIPT_DIR/test_files.sh"

pass=0
fail=0

echo "Running curl/GitHub API unit tests (utilities/comment_utility.sh, utilities/split_utility.sh)..."
if bash "$SCRIPT_DIR/test_comment_utility.sh"; then
	pass=$((pass + 1))
else
	echo "FAIL: test_comment_utility.sh reported failures"
	fail=$((fail + 1))
fi
echo

echo "Regenerating payloads from testing/gitactions_output/ into a scratch dir..."
if ! PAYLOAD_DIR="$ACTUAL_DIR" bash "$SCRIPT_DIR/generate_pr_payload.sh" >/dev/null; then
	echo "FAIL: generate_pr_payload.sh exited non-zero"
	exit 1
fi
echo

for entry in "${test_files[@]}"; do
	# shellcheck disable=SC2034 # exit_code/use_plan_file are unused here but must be captured to correctly split the "|"-delimited entry
	IFS='|' read -r command output_file exit_code use_plan_file <<<"$entry"

	input_file="$INPUT_DIR/${output_file}.txt"
	golden_file="$GOLDEN_DIR/${output_file}.json"
	actual_file="$ACTUAL_DIR/${output_file}.json"

	if [[ ! -f "$input_file" ]]; then
		echo "FAIL [$output_file]: missing input fixture $input_file"
		fail=$((fail + 1))
		continue
	fi

	if [[ ! -f "$golden_file" ]]; then
		echo "FAIL [$output_file]: missing golden payload $golden_file (run generate_pr_payload.sh to create it)"
		fail=$((fail + 1))
		continue
	fi

	if [[ ! -f "$actual_file" ]]; then
		echo "FAIL [$output_file]: generator did not produce a payload for command '$command'"
		fail=$((fail + 1))
		continue
	fi

	if ! jq empty "$actual_file" 2>/dev/null; then
		echo "FAIL [$output_file]: generated payload is not valid JSON"
		fail=$((fail + 1))
		continue
	fi

	if diff -u <(jq -S . "$golden_file") <(jq -S . "$actual_file") >/tmp/pr_payload_diff.$$; then
		echo "PASS [$output_file]"
		pass=$((pass + 1))
	else
		echo "FAIL [$output_file]: generated payload does not match golden fixture $golden_file"
		cat /tmp/pr_payload_diff.$$
		fail=$((fail + 1))
	fi
	rm -f /tmp/pr_payload_diff.$$
done

echo
echo "----"
echo "$pass passed, $fail failed"

[[ $fail -eq 0 ]]
