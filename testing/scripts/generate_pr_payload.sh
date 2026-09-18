#!/usr/bin/env bash
#
# Drives the real handlers/utilities for every fixture in test_files.sh and
# captures the PR comment payload(s) they would have posted to GitHub,
# writing each one to testing/pr_payload/<output_file>.json instead of
# calling the GitHub API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Allow callers (e.g. tests.sh) to redirect output to a scratch directory so
# the checked-in golden fixtures aren't touched.
PAYLOAD_DIR="${PAYLOAD_DIR:-$ROOT_DIR/testing/pr_payload}"

# shellcheck source=testing/scripts/test_files.sh
source "$SCRIPT_DIR/test_files.sh"

# shellcheck disable=SC1091 source=handlers/
for HF in "$ROOT_DIR"/handlers/*; do source "$HF"; done
# shellcheck disable=SC1091 source=utilities/
for UF in "$ROOT_DIR"/utilities/*; do source "$UF"; done

# Overrides the real post_comment() from utilities/comment_utility.sh so that
# no network call is made. `pr_payload` is a dynamically-scoped local set by
# the caller, make_and_post_payload().
post_comment() {
	debug "post_comment override"
	# shellcheck disable=SC2154 # pr_payload is a local set by the caller, make_and_post_payload() (see comment above)
	echo "$pr_payload" >>"$PAYLOAD_TMP_FILE"
}

# Overrides the real delete_existing_comments() from utilities/comment_utility.sh
# so that no network call is made against the (fake) PR_COMMENTS_URL. Every
# handler calls this before generating its payload, and the real
# implementation curls the GitHub API, which we don't want here.
delete_existing_comments() {
	debug "delete_existing_comments override"
}

generate_pr_payloads() {
	mkdir -p "$PAYLOAD_DIR"

	export GITHUB_TOKEN="xxx"
	GITHUB_EVENT="$(cat "$ROOT_DIR/testing/gitactions_events/pull_request.json")"
	export GITHUB_EVENT

	local entry command output_file exit_code use_plan_file

	for entry in "${test_files[@]}"; do
		IFS='|' read -r command output_file exit_code use_plan_file <<<"$entry"

		if [[ $use_plan_file == "true" ]]; then
			export COMMENTER_PLAN_FILE="$ROOT_DIR/testing/gitactions_output/${output_file}.txt"
			unset COMMENTER_INPUT
		else
			COMMENTER_INPUT="$(cat "$ROOT_DIR/testing/gitactions_output/${output_file}.txt")"
			export COMMENTER_INPUT
			unset COMMENTER_PLAN_FILE
		fi

		PAYLOAD_TMP_FILE="$(mktemp)"

		validate_inputs "$command" "$exit_code"
		parse_args "$command" "$exit_code"

		case "$command" in
		fmt) execute_fmt ;;
		init) execute_init ;;
		plan) execute_plan ;;
		validate) execute_validate ;;
		tflint) execute_tflint ;;
		*)
			info "Unsupported command: $command" >&2
			rm -f "$PAYLOAD_TMP_FILE"
			continue
			;;
		esac

		jq -s '.' "$PAYLOAD_TMP_FILE" >"$PAYLOAD_DIR/${output_file}.json"
		rm -f "$PAYLOAD_TMP_FILE"

		info "Wrote $PAYLOAD_DIR/${output_file}.json"
	done
}

generate_pr_payloads
