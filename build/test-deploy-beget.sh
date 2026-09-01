#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY="$ROOT/build/deploy-beget-release.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

without_env() {
  local name=$1 entry
  filtered_env=()
  for entry in "${base_env[@]}"; do
    [[ $entry == "$name="* ]] || filtered_env+=("$entry")
  done
}

BIN="$TMP/bin"
BUNDLE="$TMP/bundle"
RUNNER_TEMP="$TMP/runner"
CAPTURE="$TMP/capture"
mkdir -p "$BIN" "$BUNDLE" "$RUNNER_TEMP"

cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh ' >>"$CAPTURE"
printf '%q ' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
EOF
cat >"$BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp ' >>"$CAPTURE"
printf '%q ' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
EOF
chmod 700 "$BIN/ssh" "$BIN/scp"

files=(
  niiet-riscv-toolchain-linux-x86_64.tar.gz
  niiet-riscv-toolchain-linux-x86_64.zip
  niiet-riscv-toolchain-macos-aarch64.tar.gz
  niiet-riscv-toolchain-macos-aarch64.zip
  niiet-riscv-toolchain-windows-x86_64.tar.gz
  niiet-riscv-toolchain-windows-x86_64.zip
  release.json
)
for file in "${files[@]}"; do
  printf '%s\n' "$file" >"$BUNDLE/$file"
done

key='test private key must never be logged'
base_env=(
  "BEGET_HOST=example.invalid"
  "BEGET_PORT=2222"
  "BEGET_USER=baglayt2_aspect"
  "BEGET_SSH_PRIVATE_KEY=$key"
  "BEGET_KNOWN_HOSTS=example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
  "GITHUB_REPOSITORY=phlyash/riscv-toolchain"
  "GITHUB_RUN_ID=123"
  "GITHUB_RUN_ATTEMPT=2"
  "RUNNER_TEMP=$RUNNER_TEMP"
  "SSH_BIN=$BIN/ssh"
  "SCP_BIN=$BIN/scp"
  "CAPTURE=$CAPTURE"
)

for required in BEGET_HOST BEGET_PORT BEGET_USER BEGET_SSH_PRIVATE_KEY BEGET_KNOWN_HOSTS GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RUNNER_TEMP; do
  without_env "$required"
  expect_failure env "${filtered_env[@]}" "$DEPLOY" "$BUNDLE"
  expect_failure env "${base_env[@]}" "$required=" "$DEPLOY" "$BUNDLE"
done

for bad in \
  'BEGET_HOST=bad;host' \
  'BEGET_USER=bad/user' \
  'BEGET_PORT=22;2' \
  'GITHUB_REPOSITORY=someone/riscv-toolchain' \
  'GITHUB_REPOSITORY=phlyash/not-riscv-toolchain' \
  'GITHUB_RUN_ID=12/3' \
  'GITHUB_RUN_ATTEMPT=two'; do
  expect_failure env "${base_env[@]}" "$bad" "$DEPLOY" "$BUNDLE"
done

mv "$BUNDLE/release.json" "$TMP/release.json"
expect_failure env "${base_env[@]}" "$DEPLOY" "$BUNDLE"
mv "$TMP/release.json" "$BUNDLE/release.json"
printf 'unexpected\n' >"$BUNDLE/eighth-file"
expect_failure env "${base_env[@]}" "$DEPLOY" "$BUNDLE"
rm "$BUNDLE/eighth-file"
mv "$BUNDLE/release.json" "$TMP/release.json"
ln -s "$TMP/release.json" "$BUNDLE/release.json"
expect_failure env "${base_env[@]}" "$DEPLOY" "$BUNDLE"
rm "$BUNDLE/release.json"
mv "$TMP/release.json" "$BUNDLE/release.json"

output=$(env "${base_env[@]}" "$DEPLOY" "$BUNDLE" 2>&1) || fail "valid deployment failed: $output"

SSH_DIR="$RUNNER_TEMP/aspect-ssh"
[[ $(stat -c '%a' "$SSH_DIR/deploy_key") == 600 ]] || fail 'private key mode is not 600'
[[ $(stat -c '%a' "$SSH_DIR/known_hosts") == 600 ]] || fail 'known-hosts mode is not 600'
[[ $output != *"$key"* ]] || fail 'private key leaked through normal output'
[[ $(<"$CAPTURE") != *"$key"* ]] || fail 'private key leaked through transport arguments'

mapfile -t calls <"$CAPTURE"
[[ ${#calls[@]} == 3 ]] || fail "expected three transport calls, got ${#calls[@]}"
expected_ssh_options="-p 2222 -i $SSH_DIR/deploy_key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts"
[[ ${calls[0]} == "ssh $expected_ssh_options baglayt2_aspect@example.invalid aspect-publisher\\ prepare\\ 123-2 " ]] || fail "unexpected prepare call: ${calls[0]}"
[[ ${calls[2]} == "ssh $expected_ssh_options baglayt2_aspect@example.invalid aspect-publisher\\ publish\\ 123-2 " ]] || fail "unexpected publish call: ${calls[2]}"

expected_scp="scp -P 2222 -i $SSH_DIR/deploy_key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -O"
mapfile -t sorted_files < <(printf '%s\n' "${files[@]}" | sort)
for file in "${sorted_files[@]}"; do
  expected_scp+=" $BUNDLE/$file"
done
expected_scp+=' baglayt2_aspect@example.invalid:aspect-upload/123-2/ '
[[ ${calls[1]} == "$expected_scp" ]] || fail "unexpected scp call: ${calls[1]}"

printf 'PASS: deploy Beget transport contract\n'
