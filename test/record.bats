#!/usr/bin/env bats
# shellcheck disable=SC2154 # set by bats, or by setup_runner in helpers.bash
# The action's step, src/record.sh, run as the composite action runs it: inputs in INPUT_*,
# the runner's variables set, the network and horo stubbed.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  setup_runner
  # shellcheck source=horo.env
  source "$ACTION_ROOT/horo.env"
  RAN="$BATS_TEST_TMPDIR/ran"
}

record() {
  run bash "$ACTION_ROOT/src/record.sh"
}

# seed_cache: the pinned horo, already in the tool cache as a previous step left it.
seed_cache() {
  local dir="$RUNNER_TOOL_CACHE/horo/$HORO_VERSION/x64"
  mkdir -p "$dir"
  cp "$ACTION_ROOT/test/stubs/horo" "$dir/horo"
  touch "$RUNNER_TOOL_CACHE/horo/$HORO_VERSION/x64.complete"
}

assert_not_run() {
  [[ ! -e "$RAN" ]]
  [[ ! -e "$HORO_ARGS" ]]
}

# --- usage errors: the step fails and nothing runs -------------------------------------------

@test "an empty run fails before anything runs" {
  INPUT_RUN='' record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"run"* ]]
  [[ ! -e "$CURL_LOG" ]]
}

@test "an empty subject fails before anything runs" {
  INPUT_SUBJECT='' INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"subject"* ]]
  assert_not_run
  [[ ! -e "$CURL_LOG" ]]
}

@test "a matrix leg without name fails before anything runs" {
  INPUT_MATRIX='{"os":"linux"}' INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"name"* ]]
  assert_not_run
}

@test "a matrix leg with name runs" {
  seed_cache
  INPUT_MATRIX='{"os":"linux"}' INPUT_NAME=linux INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ -e "$RAN" ]]
}

@test "a job with no matrix needs no name" {
  seed_cache
  for matrix in null ''; do
    rm -f "$RAN"
    INPUT_MATRIX="$matrix" INPUT_RUN="touch $RAN" record
    [[ "$status" -eq 0 ]]
    [[ -e "$RAN" ]]
  done
}

@test "an attribute line without = fails before anything runs" {
  INPUT_ATTRIBUTES=$'team=platform\nnot an attribute' INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"not an attribute"* ]]
  assert_not_run
}

@test "a strict that is neither true nor false fails before anything runs" {
  INPUT_STRICT=yes INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"strict"* ]]
  assert_not_run
}

@test "a horo-version before 0.11.0, which has no --report, fails before anything runs" {
  for version in 0.10.9 v0.9.0 1.2 latest; do
    INPUT_HORO_VERSION="$version" INPUT_RUN="touch $RAN" record
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"::error::"*"horo-version"* ]]
    assert_not_run
  done
}

# --- unsupported platforms -------------------------------------------------------------------

@test "an unsupported platform runs the command unrecorded and passes its exit code through" {
  RUNNER_OS=Windows INPUT_RUN="touch $RAN; exit 3" record
  [[ "$status" -eq 3 ]]
  [[ -e "$RAN" ]]
  [[ "$output" == *"::warning::"*"Windows X64"* ]]
  grep -q "not recorded" "$GITHUB_STEP_SUMMARY"
  [[ ! -e "$CURL_LOG" ]]
}

@test "an unrecorded command is executed by bash -e too" {
  RUNNER_OS=Windows INPUT_RUN=$'false\ntouch '"$RAN" record
  [[ "$status" -eq 1 ]]
  [[ ! -e "$RAN" ]]
}

@test "Intel macOS is unsupported" {
  RUNNER_OS=macOS RUNNER_ARCH=X64 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"::warning::"*"macOS X64"* ]]
}

@test "an unsupported platform under strict fails before the command runs" {
  RUNNER_OS=Windows INPUT_STRICT=true INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"Windows X64"* ]]
  assert_not_run
}

# --- getting horo ----------------------------------------------------------------------------

@test "a cached horo is used without a download and put on the PATH" {
  seed_cache
  INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ -e "$RAN" ]]
  [[ ! -e "$CURL_LOG" ]]
  grep -qx "$RUNNER_TOOL_CACHE/horo/$HORO_VERSION/x64" "$GITHUB_PATH"
}

@test "the run input finds a downloaded horo first on its PATH" {
  fake_release 9.9.9 linux_amd64 > /dev/null
  INPUT_HORO_VERSION=9.9.9 INPUT_RUN="command -v horo > $RAN" record
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$RAN")" = "$RUNNER_TOOL_CACHE/horo/9.9.9/x64/horo" ]]
}

@test "the run input finds a cached horo first on its PATH" {
  seed_cache
  INPUT_RUN="command -v horo > $RAN" record
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$RAN")" = "$RUNNER_TOOL_CACHE/horo/$HORO_VERSION/x64/horo" ]]
}

@test "the pinned horo is verified against the committed sha256, not checksums.txt" {
  fake_release "$HORO_VERSION" linux_amd64 > /dev/null
  INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"sha256"*"$HORO_SHA256_linux_amd64"* ]]
  assert_not_run
  run ! grep -q checksums.txt "$CURL_LOG"
}

@test "a horo-version override installs after verifying against its checksums.txt" {
  fake_release 9.9.9 linux_arm64 > /dev/null
  RUNNER_ARCH=ARM64 INPUT_HORO_VERSION=v9.9.9 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"::notice::"*"9.9.9"*"checksums.txt"* ]]
  [[ -e "$RAN" ]]
  [[ -x "$RUNNER_TOOL_CACHE/horo/9.9.9/arm64/horo" ]]
  [[ -e "$RUNNER_TOOL_CACHE/horo/9.9.9/arm64.complete" ]]
  grep -q "/v9.9.9/horo_9.9.9_linux_arm64.tar.gz" "$CURL_LOG"
}

@test "macOS arm64 downloads the darwin build" {
  fake_release 9.9.9 darwin_arm64 > /dev/null
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 INPUT_HORO_VERSION=9.9.9 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  grep -q "horo_9.9.9_darwin_arm64.tar.gz" "$CURL_LOG"
}

@test "a checksum mismatch fails the step and does not run the command, even without strict" {
  fake_release 9.9.9 linux_amd64 > /dev/null
  sed -i.bak 's/^[0-9a-f]\{4\}/0000/' "$FAKE_RELEASES/v9.9.9/checksums.txt"
  INPUT_HORO_VERSION=9.9.9 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"sha256"* ]]
  assert_not_run
  [[ ! -e "$RUNNER_TOOL_CACHE/horo/9.9.9/x64.complete" ]]
}

@test "a failed download runs the command unrecorded with a warning" {
  INPUT_HORO_VERSION=0.404.0 INPUT_RUN="touch $RAN; exit 4" record
  [[ "$status" -eq 4 ]]
  [[ -e "$RAN" ]]
  [[ "$output" == *"::warning::"*"0.404.0"* ]]
  grep -q "not recorded" "$GITHUB_STEP_SUMMARY"
}

@test "a failed download under strict fails and does not run the command" {
  INPUT_HORO_VERSION=0.404.0 INPUT_STRICT=true INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"::error::"*"0.404.0"* ]]
  assert_not_run
}

@test "a cached override is not announced as verified" {
  local dir="$RUNNER_TOOL_CACHE/horo/9.9.9/x64"
  mkdir -p "$dir"
  cp "$ACTION_ROOT/test/stubs/horo" "$dir/horo"
  touch "$dir.complete"
  INPUT_HORO_VERSION=9.9.9 record
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"::notice::"* ]]
}

@test "a tarball without horo is a failed download, and is not cached" {
  local build="$BATS_TEST_TMPDIR/empty" dir="$FAKE_RELEASES/v9.9.9"
  mkdir -p "$build" "$dir"
  touch "$build/README"
  tar -czf "$dir/horo_9.9.9_linux_amd64.tar.gz" -C "$build" README
  printf '%s  %s\n' "$(sha256_file "$dir/horo_9.9.9_linux_amd64.tar.gz")" \
    horo_9.9.9_linux_amd64.tar.gz > "$dir/checksums.txt"
  INPUT_HORO_VERSION=9.9.9 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ -e "$RAN" ]]
  [[ "$output" == *"::warning::"* ]]
  [[ ! -e "$RUNNER_TOOL_CACHE/horo/9.9.9/x64.complete" ]]
  [[ ! -e "$RUNNER_TOOL_CACHE/horo/9.9.9/x64" ]]
}

@test "an override whose asset checksums.txt does not list is a failed download" {
  fake_release 9.9.9 linux_arm64 > /dev/null
  cp "$FAKE_RELEASES/v9.9.9/horo_9.9.9_linux_arm64.tar.gz" \
    "$FAKE_RELEASES/v9.9.9/horo_9.9.9_linux_amd64.tar.gz"
  INPUT_HORO_VERSION=9.9.9 INPUT_RUN="touch $RAN" record
  [[ "$status" -eq 0 ]]
  [[ -e "$RAN" ]]
  [[ "$output" == *"::warning::"*"checksums.txt"* ]]
}

# --- what horo run is given ------------------------------------------------------------------

@test "horo run gets the ref, defaults, automatic attributes and the command" {
  seed_cache
  record
  [[ "$status" -eq 0 ]]
  [[ "$(horo_arg_after --type)" = deployment ]]
  [[ "$(horo_arg_after --subject)" = acme/prod ]]
  [[ "$(horo_arg_after --ref)" = acme/api/123/1/deploy ]]
  [[ "$(horo_arg_after --title)" = "Deploy / deploy" ]]
  [[ "$(horo_arg_after --actor)" = octocat ]]
  [[ "$(horo_arg_after --attr)" = "$(printf '%s\n' sha=abc123 git_ref=refs/heads/main \
    workflow=Deploy run_url=https://github.com/acme/api/actions/runs/123/attempts/1)" ]]
  [[ "$(head -1 "$HORO_ARGS")" = run ]]
  [[ -n "$(horo_arg_after --report)" ]]
  [[ "$(horo_arg_after --)" = bash ]]
  [[ "$(horo_arg_after bash)" = -e ]]
  run ! grep -qx -- --strict "$HORO_ARGS"
}

@test "name is appended to the ref, and inputs replace the defaults" {
  seed_cache
  INPUT_NAME=eu INPUT_TYPE=migration INPUT_TITLE="Migrate EU" INPUT_ACTOR=robot INPUT_STRICT=true \
    record
  [[ "$status" -eq 0 ]]
  [[ "$(horo_arg_after --ref)" = acme/api/123/1/deploy/eu ]]
  [[ "$(horo_arg_after --type)" = migration ]]
  [[ "$(horo_arg_after --title)" = "Migrate EU" ]]
  [[ "$(horo_arg_after --actor)" = robot ]]
  grep -qx -- --strict "$HORO_ARGS"
}

@test "attributes follow the automatic ones, skipping blank lines and keeping = in values" {
  seed_cache
  INPUT_ATTRIBUTES=$'team=platform\n\n  sha=override  \nquery=a=b' record
  [[ "$status" -eq 0 ]]
  expected="$(printf '%s\n' team=platform sha=override query=a=b)"
  [[ "$(horo_arg_after --attr | tail -3)" = "$expected" ]]
}

@test "url and key reach horo through its environment, never its arguments" {
  seed_cache
  INPUT_URL=https://ingress.example INPUT_KEY=horo_secret record
  [[ "$status" -eq 0 ]]
  grep -qx HOROPTER_INGRESS_URL=https://ingress.example "$HORO_ARGS.env"
  grep -qx HOROPTER_INGRESS_KEY=horo_secret "$HORO_ARGS.env"
  run ! grep -q horo_secret "$HORO_ARGS"
}

@test "url and key default to the job's environment" {
  seed_cache
  HOROPTER_INGRESS_URL=https://job.example HOROPTER_INGRESS_KEY=horo_job record
  [[ "$status" -eq 0 ]]
  grep -qx HOROPTER_INGRESS_URL=https://job.example "$HORO_ARGS.env"
  grep -qx HOROPTER_INGRESS_KEY=horo_job "$HORO_ARGS.env"
}

@test "the run input is executed by bash -e" {
  seed_cache
  INPUT_RUN=$'false\ntouch '"$RAN" record
  [[ "$status" -eq 1 ]]
  [[ ! -e "$RAN" ]]
}

@test "horo run's exit code is the step's" {
  seed_cache
  FAKE_HORO_EXIT=7 record
  [[ "$status" -eq 7 ]]
}

# --- the step summary ------------------------------------------------------------------------

@test "a recorded change is summarised with its stored ref and outcome" {
  seed_cache
  fake_report '{"start_posted":true,"end_posted":true,"ref":"github/acme/api/123/1/deploy",
    "producer_ref":"acme/api/123/1/deploy","outcome":"completed","exit_code":0,"reason":null}'
  record
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" = "recorded \`github/acme/api/123/1/deploy\` (completed)" ]]
}

@test "a change whose end was not confirmed says so" {
  seed_cache
  fake_report '{"start_posted":true,"end_posted":false,"ref":"github/acme/api/123/1/deploy",
    "producer_ref":"acme/api/123/1/deploy","outcome":"failed","exit_code":1,
    "reason":"the end could not be recorded: timeout"}'
  record
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" = "recorded the start of \`github/acme/api/123/1/deploy\`, \
not its end (failed): the end could not be recorded: timeout" ]]
}

@test "an unrecorded change is summarised with horo's reason" {
  seed_cache
  fake_report '{"start_posted":false,"end_posted":false,"ref":null,
    "producer_ref":"acme/api/123/1/deploy","outcome":"completed","exit_code":0,
    "reason":"no key: set --key or HOROPTER_INGRESS_KEY to a producer key"}'
  record
  expected='not recorded: no key: set --key or HOROPTER_INGRESS_KEY to a producer key'
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" = "$expected" ]]
}

@test "an unreadable report is summarised as not recorded" {
  seed_cache
  fake_report 'not json'
  record
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" = "not recorded: horo run's report could not be read" ]]
}

@test "a missing report is summarised as not recorded" {
  seed_cache
  record
  [[ "$(cat "$GITHUB_STEP_SUMMARY")" = "not recorded: horo run wrote no report" ]]
}
