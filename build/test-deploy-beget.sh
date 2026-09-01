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

run_clean() {
  env -i "PATH=$PATH" "$@"
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
MODES="$TMP/modes"
mkdir -p "$BIN" "$BUNDLE" "$RUNNER_TEMP"

cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh ' >>"$CAPTURE"
printf '%q ' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
key_path=
known_hosts_path=
while (($#)); do
  case $1 in
    -i) key_path=$2; shift 2 ;;
    -o)
      [[ $2 == UserKnownHostsFile=* ]] && known_hosts_path=${2#UserKnownHostsFile=}
      shift 2
      ;;
    *) shift ;;
  esac
done
credential_dir=$(dirname "$key_path")
printf '%s %s %s %s %s %s\n' "$(stat -c '%a' "$key_path")" "$key_path" "$(stat -c '%a' "$known_hosts_path")" "$known_hosts_path" "$(stat -c '%a' "$credential_dir")" "$credential_dir" >>"$MODES"
EOF
cat >"$BIN/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp ' >>"$CAPTURE"
printf '%q ' "$@" >>"$CAPTURE"
printf '\n' >>"$CAPTURE"
key_path=
known_hosts_path=
while (($#)); do
  case $1 in
    -i) key_path=$2; shift 2 ;;
    -o)
      [[ $2 == UserKnownHostsFile=* ]] && known_hosts_path=${2#UserKnownHostsFile=}
      shift 2
      ;;
    *) shift ;;
  esac
done
credential_dir=$(dirname "$key_path")
printf '%s %s %s %s %s %s\n' "$(stat -c '%a' "$key_path")" "$key_path" "$(stat -c '%a' "$known_hosts_path")" "$known_hosts_path" "$(stat -c '%a' "$credential_dir")" "$credential_dir" >>"$MODES"
EOF
cat >"$BIN/failing-ssh" <<EOF
#!/usr/bin/env bash
"$BIN/ssh" "\$@"
exit 1
EOF
chmod 700 "$BIN/ssh" "$BIN/scp" "$BIN/failing-ssh"

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
  "MODES=$MODES"
)

for required in BEGET_HOST BEGET_PORT BEGET_USER BEGET_SSH_PRIVATE_KEY BEGET_KNOWN_HOSTS GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RUNNER_TEMP; do
  without_env "$required"
  expect_failure run_clean "${filtered_env[@]}" "$DEPLOY" "$BUNDLE"
  expect_failure run_clean "${base_env[@]}" "$required=" "$DEPLOY" "$BUNDLE"
done

for bad in \
  'BEGET_HOST=bad;host' \
  'BEGET_USER=bad/user' \
  'BEGET_PORT=22;2' \
  'GITHUB_REPOSITORY=someone/riscv-toolchain' \
  'GITHUB_REPOSITORY=phlyash/not-riscv-toolchain' \
  'GITHUB_RUN_ID=12/3' \
  'GITHUB_RUN_ATTEMPT=two'; do
  expect_failure run_clean "${base_env[@]}" "$bad" "$DEPLOY" "$BUNDLE"
done

mv "$BUNDLE/release.json" "$TMP/release.json"
expect_failure run_clean "${base_env[@]}" "$DEPLOY" "$BUNDLE"
mv "$TMP/release.json" "$BUNDLE/release.json"
printf 'unexpected\n' >"$BUNDLE/eighth-file"
expect_failure run_clean "${base_env[@]}" "$DEPLOY" "$BUNDLE"
rm "$BUNDLE/eighth-file"
mv "$BUNDLE/release.json" "$TMP/release.json"
ln -s "$TMP/release.json" "$BUNDLE/release.json"
expect_failure run_clean "${base_env[@]}" "$DEPLOY" "$BUNDLE"
rm "$BUNDLE/release.json"
mv "$TMP/release.json" "$BUNDLE/release.json"

PRESEEDED_DIR="$RUNNER_TEMP/aspect-ssh"
ATTACKER_KEY="$TMP/attacker-key"
ATTACKER_KNOWN_HOSTS="$TMP/attacker-known-hosts"
printf 'attacker key sentinel\n' >"$ATTACKER_KEY"
printf 'attacker known-hosts sentinel\n' >"$ATTACKER_KNOWN_HOSTS"
mkdir "$PRESEEDED_DIR"
ln -s "$ATTACKER_KEY" "$PRESEEDED_DIR/deploy_key"
ln -s "$ATTACKER_KNOWN_HOSTS" "$PRESEEDED_DIR/known_hosts"
output=$(run_clean "${base_env[@]}" "$DEPLOY" "$BUNDLE" 2>&1) || fail "valid deployment failed: $output"

[[ $(<"$ATTACKER_KEY") == 'attacker key sentinel' ]] || fail 'preseeded key symlink was overwritten'
[[ $(<"$ATTACKER_KNOWN_HOSTS") == 'attacker known-hosts sentinel' ]] || fail 'preseeded known-hosts symlink was overwritten'
[[ $output != *"$key"* ]] || fail 'private key leaked through normal output'
[[ $(<"$CAPTURE") != *"$key"* ]] || fail 'private key leaked through transport arguments'

while read -r key_mode key_path hosts_mode hosts_path directory_mode credential_dir; do
  [[ $key_mode == 600 && $hosts_mode == 600 ]] || fail 'credential files are not mode 600 during transport'
  [[ $directory_mode == 700 ]] || fail 'credential directory is not mode 700 during transport'
  [[ $key_path == "$RUNNER_TEMP"/aspect-ssh.*/* ]] || fail 'credential path is predictable'
  [[ $hosts_path == "$RUNNER_TEMP"/aspect-ssh.*/* ]] || fail 'known-hosts path is predictable'
  [[ ! -e $key_path && ! -e $hosts_path ]] || fail 'credential files were not removed after transport'
done <"$MODES"
read -r _ SSH_KEY_PATH _ SSH_KNOWN_HOSTS_PATH _ _ <"$MODES"

mapfile -t calls <"$CAPTURE"
[[ ${#calls[@]} == 3 ]] || fail "expected three transport calls, got ${#calls[@]}"
expected_ssh_options="-p 2222 -i $SSH_KEY_PATH -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_KNOWN_HOSTS_PATH"
[[ ${calls[0]} == "ssh $expected_ssh_options baglayt2_aspect@example.invalid aspect-publisher\\ prepare\\ 123-2 " ]] || fail "unexpected prepare call: ${calls[0]}"
[[ ${calls[2]} == "ssh $expected_ssh_options baglayt2_aspect@example.invalid aspect-publisher\\ publish\\ 123-2 " ]] || fail "unexpected publish call: ${calls[2]}"

expected_scp="scp -P 2222 -i $SSH_KEY_PATH -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_KNOWN_HOSTS_PATH -O"
mapfile -t sorted_files < <(printf '%s\n' "${files[@]}" | sort)
for file in "${sorted_files[@]}"; do
  expected_scp+=" $BUNDLE/$file"
done
expected_scp+=' baglayt2_aspect@example.invalid:aspect-upload/123-2/ '
[[ ${calls[1]} == "$expected_scp" ]] || fail "unexpected scp call: ${calls[1]}"

: >"$CAPTURE"
: >"$MODES"
expect_failure run_clean "${base_env[@]}" "SSH_BIN=$BIN/failing-ssh" "$DEPLOY" "$BUNDLE"
read -r failed_key_mode failed_key_path failed_hosts_mode failed_hosts_path failed_directory_mode failed_credential_dir <"$MODES"
[[ $failed_key_mode == 600 && $failed_hosts_mode == 600 ]] || fail 'failed transport credentials are not mode 600 during transport'
[[ $failed_directory_mode == 700 ]] || fail 'failed transport credential directory is not mode 700 during transport'
[[ ! -e $failed_key_path && ! -e $failed_hosts_path && ! -e $failed_credential_dir ]] || fail 'credential directory was not removed after failed transport'

HOSTILE_BUNDLE="$TMP/-bundle:host"
mkdir "$HOSTILE_BUNDLE"
for file in "${files[@]}"; do
  printf '%s\n' "$file" >"$HOSTILE_BUNDLE/$file"
done
: >"$CAPTURE"
: >"$MODES"
(cd "$TMP" && run_clean "${base_env[@]}" "$DEPLOY" '-bundle:host') || fail 'relative hostile bundle deployment failed'
mapfile -t hostile_calls <"$CAPTURE"
[[ ${#hostile_calls[@]} == 3 ]] || fail "expected three hostile transport calls, got ${#hostile_calls[@]}"
HOSTILE_ABSOLUTE=$(realpath -- "$HOSTILE_BUNDLE")
for file in "${sorted_files[@]}"; do
  [[ ${hostile_calls[1]} == *" $HOSTILE_ABSOLUTE/$file "* ]] || fail "scp local path is not canonical and absolute: $file"
done
[[ ${hostile_calls[1]} != *' -bundle:host/'* ]] || fail 'scp received a hostile relative local path'

printf 'PASS: deploy Beget transport contract\n'
