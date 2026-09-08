#!/system/bin/sh
# Mock Android commands; no real input method changes or notifications.
SCRIPT="${1:-${0%/*}/../backup.sh}"
for function_name in save_input_method restore_input_method on_exit; do
    eval "$(sed -n "/^${function_name}() {$/,/^}$/p" "$SCRIPT")"
done
test_dir=$(mktemp -d) || exit 1
trap 'rm -f "$test_dir/selection" "$test_dir/calls"; rmdir "$test_dir"' EXIT
FCITX_PACKAGE=org.fcitx.fcitx5.android
fcitx_ime="$FCITX_PACKAGE/.input.FcitxInputMethodService"
other_ime=example.keyboard/.Service
log() { :; }
sleep() { :; }
notify_result() { :; }
am() { echo 0; }
settings() { cat "$test_dir/selection"; }
ime() {
    echo "$*" >> "$test_dir/calls"
    [ "$ime_failure" = true ] && return 1
    [ "$ignore_selection" = true ] || printf '%s\n' "$4" > "$test_dir/selection"
    return 0
}
reset_case() {
    SAVED_IME=""
    IME_USER=""
    IME_RESTORE_PENDING=false
    ime_failure=false
    ignore_selection=false
    : > "$test_dir/calls"
    printf '%s\n' "$1" > "$test_dir/selection"
}
fail() { echo "FAIL: $*"; exit 1; }

reset_case "$fcitx_ime"
save_input_method || fail save
printf '%s\n' "$other_ime" > "$test_dir/selection"
restore_input_method || fail restore
[ "$(cat "$test_dir/selection")" = "$fcitx_ime" ] || fail selection
[ "$IME_RESTORE_PENDING" = false ] || fail pending
echo 'PASS: fcitx selection restored after fallback'

reset_case "$other_ime"
save_input_method && restore_input_method || fail other
[ ! -s "$test_dir/calls" ] || fail 'changed another keyboard'
echo 'PASS: another selected keyboard left alone'

reset_case null
if save_input_method; then fail 'accepted unreadable selection'; fi
echo 'PASS: missing selection prevents restart'

reset_case "$fcitx_ime"
save_input_method || fail save
ime_failure=true
if restore_input_method; then fail 'ignored ime set failure'; fi
[ "$IME_RESTORE_PENDING" = true ] || fail 'lost recovery state'
[ "$(wc -l < "$test_dir/calls" | tr -d ' ')" = 3 ] || fail retries
ime_failure=false
restore_input_method || fail recovery
echo 'PASS: bounded retries preserve state for recovery'

reset_case "$fcitx_ime"
save_input_method || fail save
printf '%s\n' "$other_ime" > "$test_dir/selection"
ignore_selection=true
if restore_input_method; then fail 'did not verify selection'; fi
echo 'PASS: successful command requires matching selection'

reset_case "$fcitx_ime"
save_input_method || fail save
printf '%s\n' "$other_ime" > "$test_dir/selection"
(
    FINAL_EXIT=0
    LOCK_HELD=false
    trap on_exit EXIT
    exit 7
)
[ "$?" = 7 ] || fail 'lost original failure code'
[ "$(cat "$test_dir/selection")" = "$fcitx_ime" ] || fail 'exit did not restore'
echo 'PASS: error exit restores selection and preserves failure code'
echo 'All input method tests passed.'
