#!/usr/bin/env bash
#
# Unit tests for the GitHub-API-calling code in utilities/comment_utility.sh
# and utilities/split_utility.sh (posting comments, listing/paginating
# comments, and deleting comments).
#
# No real network calls are made. `curl` is overridden with a bash function
# below; since bash resolves function names before searching $PATH, every
# `curl ...` invocation made by the sourced utilities in this shell runs the
# fake instead of the real binary. This lets us exercise the *real*
# URL-building, pagination, regex-filtering, and status-handling logic while
# fully controlling what the "GitHub API" returns - including edge cases
# like pagination and failed deletes that are hard to trigger against the
# real API on demand.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091 source=utilities/logging_utility.sh
source "$ROOT_DIR/utilities/logging_utility.sh"
# shellcheck disable=SC1091 source=utilities/split_utility.sh
source "$ROOT_DIR/utilities/split_utility.sh"
# shellcheck disable=SC1091 source=utilities/comment_utility.sh
source "$ROOT_DIR/utilities/comment_utility.sh"

CURL_LOG="$(mktemp)"
trap 'rm -f "$CURL_LOG"' EXIT

reset_curl_log() { : >"$CURL_LOG"; }
curl_calls_matching() { grep -c -- "$1" "$CURL_LOG" || true; }

# Fake curl. Response shape is driven by test-set globals:
#   MOCK_LINK_HEADER      - Link header line returned for the -sSI HEAD
#                           request (used by get_page_count). Unset/empty
#                           means "single page".
#   MOCK_COMMENTS_PAGE_N  - JSON body returned when the URL contains
#                           "page=N" (used by the comment-listing GET).
#   MOCK_DELETE_STATUS    - http status text returned for -X DELETE calls.
#                           Defaults to 204.
curl() {
	local all_args="$*"
	printf '%s\n' "$all_args" >>"$CURL_LOG"

	if [[ "$all_args" == *"-sSI"* ]]; then
		printf 'HTTP/2 200\r\n'
		if [[ -n "${MOCK_LINK_HEADER:-}" ]]; then
			printf '%s\r\n' "$MOCK_LINK_HEADER"
		fi
		printf '\r\n'
		return 0
	fi

	if [[ "$all_args" == *"-X DELETE"* ]]; then
		printf '%s' "${MOCK_DELETE_STATUS:-204}"
		return 0
	fi

	if [[ "$all_args" == *"-X POST"* ]]; then
		printf '{"id": 999, "body": "mocked"}'
		return 0
	fi

	if [[ "$all_args" == *"&page="* ]]; then
		local page var
		# Note: PR_COMMENTS_URL already contains "?per_page=100", so match
		# "&page=N" specifically rather than just "page=N" (which would also
		# match the "per_page=100" substring).
		page=$(grep -oE '&page=[0-9]+' <<<"$all_args" | grep -oE '[0-9]+' | head -n1)
		var="MOCK_COMMENTS_PAGE_${page}"
		printf '%s' "${!var:-[]}"
		return 0
	fi

	printf '[]'
	return 0
}

# Fixtures shared by all tests. These are consumed by the sourced functions
# in utilities/comment_utility.sh, which shellcheck can't see when linting
# this file in isolation.
# shellcheck disable=SC2034
ACCEPT_HEADER="Accept: application/vnd.github+json"
# shellcheck disable=SC2034
AUTH_HEADER="Authorization: token xxx"
# shellcheck disable=SC2034
CONTENT_HEADER="X-GitHub-Api-Version: 2022-11-28"
PR_COMMENTS_URL="https://api.github.test/repos/octo/example/issues/42/comments?per_page=100"
# shellcheck disable=SC2034
PR_COMMENT_URI="https://api.github.test/repos/octo/example/issues/comments"

pass=0
fail=0

assert_eq() {
	local expected="$1" actual="$2" msg="$3"
	if [[ "$expected" != "$actual" ]]; then
		echo "  assertion failed: $msg (expected='$expected' actual='$actual')" >&2
		return 1
	fi
}

run_test() {
	local name="$1"
	shift
	reset_curl_log
	unset FOUND MOCK_LINK_HEADER MOCK_DELETE_STATUS
	unset "${!MOCK_COMMENTS_PAGE_@}"
	if ("$@"); then
		echo "PASS [$name]"
		pass=$((pass + 1))
	else
		echo "FAIL [$name]"
		fail=$((fail + 1))
	fi
}

### get_page_count ###

test_get_page_count_single_page() {
	local PAGE_COUNT
	get_page_count PAGE_COUNT
	assert_eq "1" "$PAGE_COUNT" "PAGE_COUNT with no Link header"
}

test_get_page_count_parses_last_page_from_link_header() {
	MOCK_LINK_HEADER='Link: <https://api.github.test/comments?page=2>; rel="next", <https://api.github.test/comments?page=5>; rel="last"'
	local PAGE_COUNT
	get_page_count PAGE_COUNT
	assert_eq "5" "$PAGE_COUNT" "PAGE_COUNT parsed from Link header"
}

### delete_existing_comments ###

test_delete_existing_comments_deletes_only_matches() {
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	MOCK_COMMENTS_PAGE_1='[{"id":1,"body":"### Terraform `plan` for Workspace: `default`\nfoo"},{"id":2,"body":"unrelated comment"}]'

	local output
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	output=$(delete_existing_comments 'plan' '### Terraform `plan` .*' 2>&1) || return 1

	assert_eq "1" "$(curl_calls_matching '-X DELETE')" "expected exactly one DELETE call" || {
		echo "$output" >&2
		return 1
	}
	if ! grep -q -- "comments/1" "$CURL_LOG"; then
		echo "  expected DELETE for matching comment id 1. Log:" >&2
		cat "$CURL_LOG" >&2
		return 1
	fi
	if grep -q -- "comments/2" "$CURL_LOG"; then
		echo "  unexpectedly deleted non-matching comment id 2" >&2
		return 1
	fi
	grep -q "Found existing plan PR comment: 1" <<<"$output" || {
		echo "  missing expected info log. Got: $output" >&2
		return 1
	}
}

test_delete_existing_comments_no_matches_reports_none_found() {
	MOCK_COMMENTS_PAGE_1='[{"id":3,"body":"unrelated"}]'

	local output
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	output=$(delete_existing_comments 'plan' '### Terraform `plan` .*' 2>&1) || return 1

	assert_eq "0" "$(curl_calls_matching '-X DELETE')" "expected no DELETE calls" || {
		echo "$output" >&2
		return 1
	}
	grep -q "No existing plan PR comment found" <<<"$output" || {
		echo "  missing expected 'no existing comment' message. Got: $output" >&2
		return 1
	}
}

test_delete_existing_comments_reports_failed_delete() {
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	MOCK_COMMENTS_PAGE_1='[{"id":7,"body":"### Terraform `plan` boom"}]'
	MOCK_DELETE_STATUS=403

	local output
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	output=$(delete_existing_comments 'plan' '### Terraform `plan` .*' 2>&1) || return 1

	grep -q "Failed to delete" <<<"$output" || {
		echo "  expected a failure message on non-204 delete status. Got: $output" >&2
		return 1
	}
}

test_delete_existing_comments_paginates_and_deletes_across_pages() {
	MOCK_LINK_HEADER='Link: <https://api.github.test/comments?page=2>; rel="next", <https://api.github.test/comments?page=2>; rel="last"'
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	MOCK_COMMENTS_PAGE_1='[{"id":10,"body":"### Terraform `plan` p1"}]'
	# shellcheck disable=SC2016,SC2034 # backticks are literal markdown; consumed indirectly (${!var}) by the fake curl() in this file
	MOCK_COMMENTS_PAGE_2='[{"id":11,"body":"### Terraform `plan` p2"}]'

	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	delete_existing_comments 'plan' '### Terraform `plan` .*' >/dev/null 2>&1 || return 1

	for id in 10 11; do
		grep -q -- "comments/$id" "$CURL_LOG" || {
			echo "  expected DELETE for comment id $id across paginated results. Log:" >&2
			cat "$CURL_LOG" >&2
			return 1
		}
	done
}

test_delete_existing_comments_handles_malformed_api_response() {
	# Characterization test / known-limitation guard: if the GitHub API
	# returns an error object instead of an array of comments (e.g. rate
	# limiting, bad credentials, 404), delete_existing_comments does NOT
	# abort the calling script - it returns 0 and execution continues.
	# However it currently leaks a confusing jq parse error onto stderr
	# ("Cannot index string with string \"body\"") because the `.[] |
	# select(.body|...)` filter in delete_existing_comments (see
	# utilities/comment_utility.sh) assumes the response is always an
	# array. This test pins that *exact* known behaviour: if it starts
	# crashing the script, that's a regression; if the stderr noise goes
	# away, someone hardened the jq filter and should update this test.
	# shellcheck disable=SC2034 # consumed indirectly (${!var}) by the fake curl() in this file
	MOCK_COMMENTS_PAGE_1='{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'

	local output status
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	output=$(delete_existing_comments 'plan' '### Terraform `plan` .*' 2>&1)
	status=$?

	if [[ $status -ne 0 ]]; then
		echo "  delete_existing_comments exited $status on a malformed API response. Output:" >&2
		echo "$output" >&2
		return 1
	fi
	if ! grep -q "jq: error" <<<"$output"; then
		echo "  NOTE: malformed-response handling appears to have changed (no jq error emitted). If this is intentional hardening, update this test's expectations. Output:" >&2
		echo "$output" >&2
		return 1
	fi
}

### post_comment / make_and_post_payload ###

test_make_and_post_payload_posts_expected_body() {
	# shellcheck disable=SC2034 # read by make_and_post_payload() in the sourced utilities/comment_utility.sh
	COMMENTER_DEBUG=true
	make_and_post_payload "plan" "hello world" >/dev/null

	grep -q -- "-X POST" "$CURL_LOG" || {
		echo "  expected a POST curl call. Log:" >&2
		cat "$CURL_LOG" >&2
		return 1
	}
	grep -qF -- "$PR_COMMENTS_URL" "$CURL_LOG" || {
		echo "  POST call did not target PR_COMMENTS_URL. Log:" >&2
		cat "$CURL_LOG" >&2
		return 1
	}
	grep -qF -- '"body": "hello world"' "$CURL_LOG" || {
		echo "  expected posted payload to contain the comment body. Log:" >&2
		cat "$CURL_LOG" >&2
		return 1
	}
}

run_test "get_page_count: single page (no Link header)" test_get_page_count_single_page
run_test "get_page_count: parses last page from Link header" test_get_page_count_parses_last_page_from_link_header
run_test "delete_existing_comments: deletes only regex matches" test_delete_existing_comments_deletes_only_matches
run_test "delete_existing_comments: reports none found" test_delete_existing_comments_no_matches_reports_none_found
run_test "delete_existing_comments: reports failed delete on non-204" test_delete_existing_comments_reports_failed_delete
run_test "delete_existing_comments: paginates across multiple pages" test_delete_existing_comments_paginates_and_deletes_across_pages
run_test "delete_existing_comments: survives malformed API response" test_delete_existing_comments_handles_malformed_api_response
run_test "make_and_post_payload: posts expected JSON body" test_make_and_post_payload_posts_expected_body

echo
echo "----"
echo "$pass passed, $fail failed"

[[ $fail -eq 0 ]]
