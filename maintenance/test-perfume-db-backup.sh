#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIVER="$ROOT/maintenance/perfume-db-receive.sh"
CONSUMER="$ROOT/maintenance/perfume-db-backup.sh"
NIGHT_RUN="$ROOT/maintenance/night-run.sh"
INSTALLER="$ROOT/install.sh"
VERIFY="$ROOT/verify.sh"

grep -Fq '/usr/local/bin/perfume-db-backup.sh' "$NIGHT_RUN" || { echo 'FAIL: nightly runner does not invoke the perfume DB consumer' >&2; exit 1; }
grep -Fq 'ventas-campaign-active' "$NIGHT_RUN" || { echo 'FAIL: nightly runner lost the live sales-campaign guard' >&2; exit 1; }
grep -Fq '"perfume-db-receive.sh"' "$INSTALLER" || { echo 'FAIL: installer does not install the receiver' >&2; exit 1; }
grep -Fq '"perfume-db-backup.sh"' "$INSTALLER" || { echo 'FAIL: installer does not install the nightly consumer' >&2; exit 1; }
grep -Fq '/usr/local/bin/perfume-db-receive.sh' "$VERIFY" || { echo 'FAIL: verify does not check the receiver installation' >&2; exit 1; }
grep -Fq '/usr/local/bin/perfume-db-backup.sh' "$VERIFY" || { echo 'FAIL: verify does not check the consumer installation' >&2; exit 1; }
grep -Eq '0 2 \* \* \* /usr/local/bin/night-run\.sh' "$INSTALLER" || { echo 'FAIL: installer does not schedule the nightly runner at 02:00' >&2; exit 1; }
echo 'PASS: installer and 02:00 nightly schedule include the backup consumer'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/perfume-db-backup-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT INT TERM

REAL_PYTHON="$(command -v python3)"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/disk1" "$TEST_ROOT/disk2"
cat > "$TEST_ROOT/bin/mountpoint" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-q" && -f "${2:-}/.mounted" ]]
SH
cat > "$TEST_ROOT/bin/findmnt" <<'SH'
#!/usr/bin/env bash
target=""
while (($#)); do
  if [[ "$1" == "--target" ]]; then target="$2"; shift 2; else shift; fi
done
if [[ "$target" == "/" ]]; then echo /dev/mmcblk0p2; exit 0; fi
[[ -f "$target/.mounted" ]] || exit 1
case "$target" in
  */disk1) echo /dev/sda1 ;;
  */disk2) echo /dev/sdb1 ;;
  *) exit 1 ;;
esac
SH
cat > "$TEST_ROOT/bin/df" <<'SH'
#!/usr/bin/env bash
target="${@: -1}"
printf 'Avail\n'
if [[ -f "$target/.free" ]]; then cat "$target/.free"; else echo 1073741824; fi
SH
cat > "$TEST_ROOT/bin/cp" <<'SH'
#!/usr/bin/env bash
if [[ "${FAIL_CP:-0}" == 1 ]]; then exit 77; fi
exec "${REAL_CP:?}" "$@"
SH
cat > "$TEST_ROOT/bin/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${FAIL_MANIFEST_WRITE:-0}" == 1 && "${2:-}" == *perfume-app.sqlite.json.new.* ]]; then exit 78; fi
exec "${REAL_PYTHON:?}" "$@"
SH
chmod +x "$TEST_ROOT/bin/"*
REAL_CP="$(command -v cp)"
export REAL_CP REAL_PYTHON
export PATH="$TEST_ROOT/bin:$PATH"

DISK1="$TEST_ROOT/disk1"
DISK2="$TEST_ROOT/disk2"
export PERFUME_DB_PHOTOS_MOUNT="$DISK1"
export PERFUME_DB_BACKUP_MOUNT="$DISK2"
export PERFUME_DB_STABLE_DIR="$DISK2/stable/perfume-db"
export PERFUME_DB_MIN_FREE_BYTES=1024
touch "$DISK1/.mounted" "$DISK2/.mounted"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

new_fixture() {
  local db="$1" value="$2"
  python3 - "$db" "$value" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE sample (value TEXT NOT NULL)")
db.execute("INSERT INTO sample(value) VALUES (?)", (sys.argv[2],))
db.commit()
db.close()
PY
}

read_value() {
  python3 - "$1" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(db.execute("SELECT value FROM sample").fetchone()[0])
db.close()
PY
}

receive_fixture() {
  local fixture="$1" id="$2" expected_disk="$3" size sha response partial
  size="$(stat -c '%s' "$fixture")"
  sha="$(sha256sum "$fixture" | awk '{print $1}')"
  response="$("$RECEIVER" prepare "$id" "$size" "$sha")" || fail "receiver prepare returned failure: $response"
  [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["disk"])' <<< "$response")" == "$expected_disk" ]] || fail "receiver picked an unexpected disk"
  partial="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["stagingPath"])' <<< "$response")"
  cp -- "$fixture" "$partial"
  response="$("$RECEIVER" commit "$id" "$size" "$sha")" || fail "receiver commit returned failure: $response"
  [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["disk"])' <<< "$response")" == "$expected_disk" ]] || fail "commit marker has the wrong disk"
}

run_consumer() {
  "$CONSUMER"
}

FIXTURE1="$TEST_ROOT/fixture-one.sqlite"
new_fixture "$FIXTURE1" one
ID1="11111111-1111-4111-8111-111111111111"
receive_fixture "$FIXTURE1" "$ID1" primary
[[ -f "$DISK1/perfume-db/incoming/perfume-app.ready.json" ]] || fail "primary ready marker missing"
run_consumer
STABLE="$PERFUME_DB_STABLE_DIR/perfume-app.sqlite"
[[ "$(read_value "$STABLE")" == one ]] || fail "primary-origin copy was not installed"
[[ ! -e "$DISK1/perfume-db/incoming/perfume-app.ready.json" ]] || fail "consumed primary marker remains"
pass "primary mounted disk receives and nightly consumer installs the verified database"

FIXTURE2="$TEST_ROOT/fixture-two.sqlite"
new_fixture "$FIXTURE2" two
rm -f "$DISK1/.mounted"
ID2="22222222-2222-4222-8222-222222222222"
receive_fixture "$FIXTURE2" "$ID2" secondary
run_consumer
[[ "$(read_value "$STABLE")" == two ]] || fail "secondary fallback was not installed"
[[ ! -e "$DISK2/perfume-db/incoming/perfume-app.ready.json" ]] || fail "consumed secondary marker remains"
pass "primary absent falls back directly to secondary and nightly consumer recognizes it"

FIXTURE3="$TEST_ROOT/fixture-three.sqlite"
new_fixture "$FIXTURE3" three
ID3="33333333-3333-4333-8333-333333333333"
size3="$(stat -c '%s' "$FIXTURE3")"
sha3="$(sha256sum "$FIXTURE3" | awk '{print $1}')"
touch "$DISK1/.mounted"
echo 100 > "$DISK1/.free"
echo 1073741824 > "$DISK2/.free"
receive_fixture "$FIXTURE3" "$ID3" secondary
pass "unusable primary (insufficient space) falls back to secondary"

rm -f "$DISK1/.mounted" "$DISK2/.mounted"
ID4="44444444-4444-4444-8444-444444444444"
set +e
no_disk_response="$("$RECEIVER" prepare "$ID4" "$size3" "$sha3" 2>&1)"
no_disk_rc=$?
set -e
[[ "$no_disk_rc" -eq 2 ]] || fail "both-unmounted prepare unexpectedly succeeded"
[[ ! -e "$DISK1/perfume-db/incoming/.perfume-app.sqlite.$ID4.partial" ]] || fail "receiver wrote on an unmounted primary path"
pass "both external disks absent is a hard failure with no internal staging"

touch "$DISK2/.mounted"
run_consumer
[[ "$(read_value "$STABLE")" == three ]] || fail "secondary source after disk outage was not consumed"
pass "secondary ready copy is consumed after disk returns"

# A directory under an external mount must not redirect writes to TV Box flash.
rm -rf -- "$DISK1/perfume-db"
mkdir -p "$TEST_ROOT/internal-escape"
ln -s "$TEST_ROOT/internal-escape" "$DISK1/perfume-db"
FIXTURE_SYMLINK="$TEST_ROOT/fixture-symlink.sqlite"
new_fixture "$FIXTURE_SYMLINK" symlink
ID_SYMLINK="66666666-6666-4666-8666-666666666666"
receive_fixture "$FIXTURE_SYMLINK" "$ID_SYMLINK" secondary
[[ ! -e "$TEST_ROOT/internal-escape/incoming" ]] || fail "receiver followed a symlink into internal storage"
rm -f -- "$DISK1/perfume-db"
mkdir -p "$DISK1/perfume-db"
run_consumer
[[ "$(read_value "$STABLE")" == symlink ]] || fail "safe secondary copy was not consumed after symlink rejection"
pass "receiver refuses nested symlinks that could redirect to internal storage"

# The nightly stable destination must also remain a real directory on disk 2.
FIXTURE_DEST_SYMLINK="$TEST_ROOT/fixture-destination-symlink.sqlite"
new_fixture "$FIXTURE_DEST_SYMLINK" destination-symlink
ID_DEST_SYMLINK="77777777-7777-4777-8777-777777777777"
receive_fixture "$FIXTURE_DEST_SYMLINK" "$ID_DEST_SYMLINK" secondary
mkdir -p "$TEST_ROOT/internal-destination"
ln -s "$TEST_ROOT/internal-destination" "$DISK2/escape"
set +e
PERFUME_DB_STABLE_DIR="$DISK2/escape/perfume-db" run_consumer >/dev/null 2>&1
destination_rc=$?
set -e
[[ "$destination_rc" -ne 0 ]] || fail "nightly consumer followed a symlink outside the secondary disk"
[[ "$(read_value "$STABLE")" == symlink ]] || fail "unsafe destination changed the previous stable backup"
[[ ! -e "$TEST_ROOT/internal-destination/perfume-db" ]] || fail "nightly consumer wrote through the destination symlink"
[[ -f "$DISK2/perfume-db/incoming/perfume-app.ready.json" ]] || fail "unsafe destination consumed the ready marker"
rm -f -- "$DISK2/escape"
run_consumer
[[ "$(read_value "$STABLE")" == destination-symlink ]] || fail "safe retry after destination refusal was not consumed"
pass "nightly consumer refuses symlinked destinations and preserves old backup for retry"

# Validation failure must keep the last stable copy and leave the source queued.
FIXTURE4="$TEST_ROOT/fixture-four.sqlite"
new_fixture "$FIXTURE4" four
ID5="55555555-5555-4555-8555-555555555555"
receive_fixture "$FIXTURE4" "$ID5" secondary
ready="$DISK2/perfume-db/incoming/perfume-app.ready.json"
python3 - "$ready" <<'PY'
import json, sys
p=sys.argv[1]
obj=json.load(open(p, encoding="utf-8")); obj["sha256"]="0"*64
with open(p,"w",encoding="utf-8") as f: json.dump(obj,f)
PY
set +e
run_consumer >/dev/null 2>&1
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] || fail "bad source hash unexpectedly passed validation"
[[ "$(read_value "$STABLE")" == destination-symlink ]] || fail "validation failure changed stable database"
[[ -f "$ready" ]] || fail "validation failure consumed source marker"
pass "invalid received hash preserves previous stable backup and source for retry"

# Simulate failure after the new database was atomically installed but before
# its manifest was published; cleanup must restore the previous DB and manifest.
python3 - "$ready" <<'PY'
import hashlib, json, os, sys
ready=sys.argv[1]
obj=json.load(open(ready,encoding="utf-8"))
source=os.path.join(os.path.dirname(ready),obj["databaseFile"])
data=open(source,"rb").read()
obj["sizeBytes"]=len(data); obj["sha256"]=hashlib.sha256(data).hexdigest()
with open(ready,"w",encoding="utf-8") as f: json.dump(obj,f)
PY
before_manifest="$(sha256sum "$PERFUME_DB_STABLE_DIR/perfume-app.sqlite.json" | awk '{print $1}')"
set +e
FAIL_MANIFEST_WRITE=1 run_consumer >/dev/null 2>&1
rollback_rc=$?
set -e
[[ "$rollback_rc" -ne 0 ]] || fail "injected manifest failure unexpectedly succeeded"
[[ "$(read_value "$STABLE")" == destination-symlink ]] || fail "manifest failure did not restore the previous database"
after_manifest="$(sha256sum "$PERFUME_DB_STABLE_DIR/perfume-app.sqlite.json" | awk '{print $1}')"
[[ "$before_manifest" == "$after_manifest" ]] || fail "manifest failure did not restore the previous manifest"
[[ -f "$ready" ]] || fail "manifest failure consumed source marker"
pass "post-install failure restores previous DB and manifest, retaining source"

echo "PASS: isolated backup flow scenario suite"
