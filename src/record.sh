#!/usr/bin/env bash
# The action's one step: check the inputs, get horo, and run the command under horo run.
# Inputs arrive as INPUT_* variables; the step exits with horo run's exit code.
set -euo pipefail

: "${RUNNER_TEMP:?}" "${RUNNER_TOOL_CACHE:?}" "${GITHUB_STEP_SUMMARY:?}" "${GITHUB_PATH:?}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}" "${GITHUB_JOB:?}"
: "${GITHUB_SHA:?}" "${GITHUB_REF:?}" "${GITHUB_SERVER_URL:?}" "${GITHUB_WORKFLOW:?}"
: "${GITHUB_TRIGGERING_ACTOR:?}"

ACTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASES=https://github.com/horopter-dev/horopter/releases/download
# shellcheck source=horo.env
source "$ACTION_ROOT/horo.env"

fail() {
  echo "::error::$*"
  exit 1
}

is_strict() { [[ "${INPUT_STRICT:-false}" = true ]]; }

# unrecorded <reason>: Horopter is out of reach. Under strict the step fails; otherwise the
# command runs without horo, its exit code passing through.
unrecorded() {
  if is_strict; then
    summarise "not recorded: $1; strict, so the command was not run"
    fail "$1; strict, so the command was not run"
  fi
  echo "::warning::$1; running the command unrecorded"
  summarise "not recorded: $1"
  local status=0
  bash -e "$SCRIPT" || status=$?
  exit "$status"
}

summarise() { printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; }

check_inputs() {
  [[ -n "${INPUT_RUN:-}" ]] || fail "run is empty: give the command to record"
  [[ -n "${INPUT_SUBJECT:-}" ]] || fail "subject is empty: give the thing changed, e.g. acme/prod"
  case "${INPUT_MATRIX:-null}" in
    null | '') ;;
    *) [[ -n "${INPUT_NAME:-}" ]] || fail "name is empty in a matrix job: every leg shares" \
      "the job's ref, so give each leg its own name, e.g. name: \${{ matrix.os }}" ;;
  esac
  case "${INPUT_STRICT:-false}" in
    true | false) ;;
    *) fail "strict is \"$INPUT_STRICT\": give true or false" ;;
  esac
  local line
  while IFS= read -r line; do
    line="$(trim "$line")"
    [[ -z "$line" ]] || [[ "$line" =~ ^[^=]+= ]] || fail "attributes: \"$line\" is not key=value"
  done <<< "${INPUT_ATTRIBUTES:-}"
  check_horo_version
}

# check_horo_version: sets VERSION to the horo to run, without its v. horo before 0.11.0 has no
# --report, which the step summary needs.
check_horo_version() {
  VERSION="${INPUT_HORO_VERSION:-$HORO_VERSION}"
  VERSION="${VERSION#v}"
  [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] \
    || fail "horo-version is \"$INPUT_HORO_VERSION\": give a release, e.g. v$HORO_VERSION"
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}"
  ((major > 0 || minor >= 11)) || fail "horo-version is $VERSION: the action needs 0.11.0 or" \
    "later, the first horo whose run writes a report"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# platform: horo's name for this runner, or nothing when horo has no build for it.
platform() {
  case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
    Linux/X64) echo linux_amd64 ;;
    Linux/ARM64) echo linux_arm64 ;;
    macOS/ARM64) echo darwin_arm64 ;;
    *) ;;
  esac
}

sha256_of() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# expected_sha256 <version> <asset> <platform>: the committed sha256 for the pinned version, or
# the one for asset in that release's checksums.txt, with a notice. Fails when checksums.txt
# cannot be had or does not list asset.
expected_sha256() {
  local version="$1" asset="$2" platform="$3" sums
  if [[ "$version" = "$HORO_VERSION" ]]; then
    local pinned="HORO_SHA256_$platform"
    echo "${!pinned}"
    return
  fi
  echo "::notice::horo $version is not this release's pin:" \
    "verifying it against its checksums.txt" >&2
  sums="$(curl -fsSL --retry 3 "$RELEASES/v$version/checksums.txt")" || return 1
  awk -v asset="$asset" '$2 == asset { print $1 }' <<< "$sums" | grep . || return 1
}

# install_horo <version> <platform>: puts horo in the tool cache and on the PATH, and sets
# HORO_DIR to its directory. Returns 1 when the download failed; a checksum mismatch fails the
# step outright.
install_horo() {
  local version="$1" platform="$2" arch
  arch="$(tr '[:upper:]' '[:lower:]' <<< "$RUNNER_ARCH")"
  local dir="$RUNNER_TOOL_CACHE/horo/$version/$arch"
  if [[ ! -f "$dir.complete" ]]; then
    local asset="horo_${version}_${platform}.tar.gz" expected actual tmp
    tmp="$(mktemp -d "$RUNNER_TEMP/horo.XXXXXX")"
    expected="$(expected_sha256 "$version" "$asset" "$platform")" || return 1
    curl -fsSL --retry 3 -o "$tmp/$asset" "$RELEASES/v$version/$asset" || return 1
    actual="$(sha256_of "$tmp/$asset")"
    [[ "$actual" = "$expected" ]] || fail "$asset has sha256 $actual, not $expected:" \
      "corrupt, or not the file released, so it was not run"
    tar -xzf "$tmp/$asset" -C "$tmp" horo || return 1
    mkdir -p "$dir" && mv "$tmp/horo" "$dir/horo" || return 1
    touch "$dir.complete"
  fi
  echo "$dir" >> "$GITHUB_PATH"
  HORO_DIR="$dir"
}

# horo_args: sets args to horo run's arguments, up to --report.
horo_args() {
  local run="$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT"
  local ref="$GITHUB_REPOSITORY/$GITHUB_RUN_ID/$GITHUB_RUN_ATTEMPT/$GITHUB_JOB"
  [[ -z "${INPUT_NAME:-}" ]] || ref="$ref/$INPUT_NAME"
  args=(run --type "${INPUT_TYPE:-deployment}" --subject "$INPUT_SUBJECT" --ref "$ref"
    --title "${INPUT_TITLE:-$GITHUB_WORKFLOW / $GITHUB_JOB}"
    --actor "${INPUT_ACTOR:-$GITHUB_TRIGGERING_ACTOR}"
    --attr "sha=$GITHUB_SHA" --attr "git_ref=$GITHUB_REF" --attr "workflow=$GITHUB_WORKFLOW"
    --attr "run_url=$GITHUB_SERVER_URL/$run")
  local line
  while IFS= read -r line; do
    line="$(trim "$line")"
    [[ -z "$line" ]] || args+=(--attr "$line")
  done <<< "${INPUT_ATTRIBUTES:-}"
  ! is_strict || args+=(--strict)
}

# summary_of <report>: the step summary's line for what horo run reported.
summary_of() {
  [[ -s "$1" ]] || {
    echo "not recorded: horo run wrote no report"
    return
  }
  jq -r '
    if .ref != null and .end_posted then "recorded `\(.ref)` (\(.outcome))"
    elif .ref != null then "recorded the start of `\(.ref)`, not its end (\(.outcome)): \(.reason)"
    else "not recorded: \(.reason)" end' "$1" 2> /dev/null \
    || echo "not recorded: horo run's report could not be read"
}

main() {
  check_inputs
  SCRIPT="$(mktemp "$RUNNER_TEMP/record-action.XXXXXX")"
  printf '%s\n' "$INPUT_RUN" > "$SCRIPT"
  local platform
  platform="$(platform)"
  [[ -n "$platform" ]] || unrecorded "horo has no build for $RUNNER_OS $RUNNER_ARCH"
  install_horo "$VERSION" "$platform" \
    || unrecorded "could not download horo $VERSION, or its checksums.txt"

  local report status=0
  report="$(mktemp "$RUNNER_TEMP/record-action-report.XXXXXX")"
  horo_args
  HOROPTER_INGRESS_URL="${INPUT_URL:-${HOROPTER_INGRESS_URL:-}}" \
    HOROPTER_INGRESS_KEY="${INPUT_KEY:-${HOROPTER_INGRESS_KEY:-}}" \
    "$HORO_DIR/horo" "${args[@]}" --report "$report" -- bash -e "$SCRIPT" || status=$?
  summarise "$(summary_of "$report")"
  exit "$status"
}

main
