#!/system/bin/sh
# Exercise the production parser without running sync or posting notifications.
SCRIPT="${1:-${0%/*}/../backup.sh}"
eval "$(sed -n '/^parse_transfer_amount() {$/,/^}$/p' "$SCRIPT")"
fixture=$(mktemp) || exit 1
trap 'rm -f "$fixture"' EXIT

check() {
    expected="$1"
    name="$2"
    cat > "$fixture"
    actual=$(parse_transfer_amount "$fixture")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s: expected <%s>, got <%s>\n' "$name" "$expected" "$actual"
        exit 1
    fi
    printf 'PASS: %s\n' "$name"
}

check '0 B' 'DNS failure after zero-byte stats' <<'EOF'
2026/09/08 00:27:20 NOTICE:           0 B / 0 B, -, 0 B/s, ETA -
2026/09/08 00:27:22 NOTICE: Failed to sync: operation error S3: ListObjects, Get "https://s3.example.test/Rime": dial tcp: lookup s3.example.test on [::1]:53: read: connection refused
EOF

check '3.035 MiB' 'partial transfer followed by failure' <<'EOF'
2026/09/08 00:27:20 NOTICE: 3.035 MiB / 5 MiB, 60%, 1 MiB/s, ETA 2s
2026/09/08 00:27:22 NOTICE: Failed to sync: Get "https://s3.example.test/Rime": timeout
EOF

check '6.037 MiB' 'multiline byte stats followed by file counts' <<'EOF'
Transferred:        6.037 MiB / 6.037 MiB, 100%, 1 MiB/s, ETA 0s
Transferred:                4 / 4, 100%
EOF

check '11.363 MiB' 'latest valid stat across formats' <<'EOF'
Transferred: 3.001 MiB / 11.363 MiB, 26%
2026/09/08 00:27:20 NOTICE: 11.363 MiB / 11.363 MiB, 100%, 1 MiB/s, ETA 0s
EOF

check '1.5 GiB' 'larger unit and whitespace normalization' <<'EOF'
2026/09/08 00:27:20 NOTICE: 1.5    GiB / 2 GiB, 75%
EOF

check '0 B' 'error without byte stats' <<'EOF'
2026/09/08 00:27:22 NOTICE: Failed to sync: Get "https://s3.example.test/Rime": timeout
Transferred: 4 / 4, 100%
EOF

check '0 B' 'empty output' < /dev/null
printf 'All transfer amount tests passed.\n'
