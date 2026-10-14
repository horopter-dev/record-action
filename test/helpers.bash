# shellcheck shell=bash
# shellcheck disable=SC2154 # BATS_* are set by bats
# Shared set-up: a clean environment that declares what it needs, stubs for the network and
# for horo, and a fake runner. Loaded by every test file.

ACTION_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_runner() {
  local keep
  for keep in $(compgen -e); do
    case "$keep" in
      PATH | HOME | TMPDIR | LANG | LC_* | BATS_* | ACTION_ROOT) ;;
      *) unset "$keep" ;;
    esac
  done
  export PATH="$ACTION_ROOT/test/stubs:$PATH"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/temp"
  export RUNNER_TOOL_CACHE="$BATS_TEST_TMPDIR/toolcache"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path"
  export FAKE_RELEASES="$BATS_TEST_TMPDIR/releases"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export HORO_ARGS="$BATS_TEST_TMPDIR/horo.args"
  export RUNNER_OS=Linux RUNNER_ARCH=X64
  export GITHUB_REPOSITORY=acme/api GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=deploy
  export GITHUB_WORKFLOW=Deploy GITHUB_TRIGGERING_ACTOR=octocat GITHUB_SHA=abc123
  export GITHUB_REF=refs/heads/main GITHUB_SERVER_URL=https://github.com
  export INPUT_RUN='echo deployed' INPUT_SUBJECT=acme/prod INPUT_TYPE=deployment
  export INPUT_STRICT=false INPUT_MATRIX=null
  mkdir -p "$RUNNER_TEMP" "$RUNNER_TOOL_CACHE" "$FAKE_RELEASES"
  : > "$GITHUB_STEP_SUMMARY"
}

sha256_file() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fake_release <version> <platform>: puts a horo tarball holding the horo stub where the curl stub
# serves it, plus a checksums.txt naming it, and prints the tarball's sha256.
fake_release() {
  local version="$1" platform="$2" dir="$FAKE_RELEASES/v$1" build="$BATS_TEST_TMPDIR/build"
  local asset="horo_${version}_${platform}.tar.gz"
  mkdir -p "$dir" "$build"
  cp "$ACTION_ROOT/test/stubs/horo" "$build/horo"
  tar -czf "$dir/$asset" -C "$build" horo
  printf '%s  %s\n' "$(sha256_file "$dir/$asset")" "$asset" >> "$dir/checksums.txt"
  sha256_file "$dir/$asset"
}

# fake_report <json>: the report the horo stub writes.
fake_report() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/report.json"
  export FAKE_REPORT="$BATS_TEST_TMPDIR/report.json"
}

# horo_arg_after <flag>: every value horo was given for flag, one per line.
horo_arg_after() {
  local flag="$1" prev="" arg
  while IFS= read -r arg; do
    [[ "$prev" = "$flag" ]] && printf '%s\n' "$arg"
    prev="$arg"
  done < "$HORO_ARGS"
}
