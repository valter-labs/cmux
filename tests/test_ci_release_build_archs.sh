#!/usr/bin/env bash
# The CI Release check is universal unless a maintainer opts into arm64, and
# published nightly builds remain universal; unsigned build-only runs may opt in.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/ci/release-build-archs.sh"

expect() {
  local input="$1" want="$2" got
  got="$("$RESOLVER" "$input")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: '$input' resolved to '$got', expected '$want'"
    exit 1
  fi
}

expect "" "arm64 x86_64"
expect "default" "arm64 x86_64"
expect "universal" "arm64 x86_64"
expect "arm64" "arm64"
if [[ "$("$RESOLVER")" != "arm64 x86_64" ]]; then
  echo "FAIL: no argument must resolve to the universal build"
  exit 1
fi

for bad in "x86_64" "arm64 x86_64" "ARM64" "arm64;rm -rf /"; do
  if "$RESOLVER" "$bad" >/dev/null 2>&1; then
    echo "FAIL: '$bad' must be rejected, not silently narrowed or widened"
    exit 1
  fi
done

# Slice verification is exact: an arm64 check must reject a universal binary,
# or a change that brings the Intel compile back would pass unnoticed.
VERIFIER="$ROOT_DIR/scripts/ci/verify-binary-archs.sh"
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT
cat > "$FAKE_BIN/lipo" <<'LIPO'
#!/usr/bin/env bash
# Stand-in for lipo -archs <binary>: the fixture file holds its slice list.
[[ "$1" == "-archs" ]] || exit 2
cat "$2"
LIPO
chmod +x "$FAKE_BIN/lipo"
echo "arm64" > "$FAKE_BIN/thin"
echo "x86_64 arm64" > "$FAKE_BIN/universal"
echo "x86_64" > "$FAKE_BIN/intel"

verify() { PATH="$FAKE_BIN:$PATH" "$VERIFIER" "$@" >/dev/null 2>&1; }

verify "arm64" "$FAKE_BIN/thin" || { echo "FAIL: an arm64 binary must pass the arm64 check"; exit 1; }
verify "arm64 x86_64" "$FAKE_BIN/universal" || { echo "FAIL: a universal binary must pass the universal check"; exit 1; }
if verify "arm64" "$FAKE_BIN/universal"; then
  echo "FAIL: a universal binary must not pass the arm64 check"
  exit 1
fi
if verify "arm64 x86_64" "$FAKE_BIN/thin"; then
  echo "FAIL: an arm64 binary must not pass the universal check"
  exit 1
fi
if verify "arm64" "$FAKE_BIN/thin" "$FAKE_BIN/intel"; then
  echo "FAIL: every listed binary must match, not just the first"
  exit 1
fi
if verify "arm64"; then
  echo "FAIL: the verifier must refuse to run without a binary"
  exit 1
fi

# The resolver's presence alone cannot distinguish an unsigned measurement from
# publication. Exercise the workflow's gates and architecture selection instead.
bash "$ROOT_DIR/tests/test_nightly_universal_build.sh"

python3 "$ROOT_DIR/tests/test_ci_release_helper_archs.py"

echo "PASS: CI Release and unsigned build-only ARM64 are opt-in; published nightly stays universal"
