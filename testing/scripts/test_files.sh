#!/usr/bin/env bash
# List of test fixtures used by generate_pr_payload.sh.
# Each entry is a "|"-delimited tuple of:
#   command|output_file|exit_code|use_commenter_plan_file
#
#   command                 - one of fmt|init|plan|validate|tflint
#   output_file             - basename (no extension) of the fixture in
#                             testing/gitactions_output/
#   exit_code               - the Terraform/tflint CLI exit code to simulate
#   use_commenter_plan_file - "true" to feed the fixture via COMMENTER_PLAN_FILE
#                             (as terraform plan does), "false" to feed it via
#                             COMMENTER_INPUT
# shellcheck disable=SC2034 # consumed by generate_pr_payload.sh and tests.sh, which source this file
test_files=(
	"init|tf_init_fail|1|false"
	"fmt|tf_fmt_fail|1|false"
	"validate|tf_validate_fail|1|false"
	"plan|tf_plan_fail|1|false"
	"plan|tf_plan_fail_partial|1|false"
	"plan|tf_plan_success_no_changes|0|false"
	"plan|tf_plan_success_with_changes|2|false"
	"plan|tf_plan_success_with_outputs|0|false"
	"plan|tf_plan_success_long|2|true"
	"tflint|tflint_fail|2|false"
)
