#!/usr/bin/env bash
# Run with Bash 3.2+; source this file to test the pure helpers.
set -euo pipefail

platform() {
    local os arch
    case "$1" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *) echo "Unsupported OS: $1" >&2; return 1 ;;
    esac
    case "$2" in
        aarch64|arm64) arch=arm64 ;;
        x86_64|amd64) arch=amd64 ;;
        *) echo "Unsupported architecture: $2" >&2; return 1 ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

verify_report() {
    local scenario=$1 report=$2 rc=$3
    [[ -s "$report" ]] || return 1
    # A mismatch normally exits 1; errors can also exit 1. Require the report.
    case "$scenario:$rc" in consistent:0|inconsistent:0|inconsistent:1) ;; *) return 1 ;; esac
    awk -F '|' -v scenario="$scenario" '
        /`demo`\.`items`/ {
            for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if (scenario == "consistent" && NF == 5 && $3 == "3" && $4 == "3") ok=1
            if (scenario == "inconsistent" && NF == 8 && $3 == "succeed" && $4 == "true" && $5 == "+2/-2" && $6 == "3" && $7 == "3") ok=1
        }
        END { exit !ok }
    ' "$report"
}

usage() {
    echo "Usage: bash demo.sh [all|consistent|inconsistent]"
}

cleanup() {
    local rc=$?
    trap - EXIT
    for container in "$mysql_id" "$tidb_id"; do
        if [[ -n "$container" ]]; then
            docker logs "$container" > "$run_dir/$container.log" 2>&1 || true
            docker rm -fv "$container" >/dev/null || true
        fi
    done
    if [[ -n "$network_id" ]]; then docker network rm "$network_id" >/dev/null || true; fi
    echo "Reports: $run_dir"
    exit "$rc"
}

sql() {
    local target=$1
    shift
    if [[ "$target" == mysql ]]; then
        docker exec -i "$mysql_id" mysql --protocol=tcp -h127.0.0.1 -uroot "$@"
    else
        docker exec -i "$mysql_id" mysql --protocol=tcp -htidb -P4000 -uroot "$@"
    fi
}

wait_ready() {
    local target=$1 i
    for ((i=0; i<90; i++)); do
        if sql "$target" -e 'SELECT 1' >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    echo "$target did not become ready within 180 seconds" >&2
    return 1
}

run_case() {
    local scenario=$1 case_dir="$run_dir/$1" rc=0
    mkdir -p "$case_dir"
    for target in mysql tidb; do
        sql "$target" <<'SQL'
DROP DATABASE IF EXISTS demo;
CREATE DATABASE demo CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE TABLE demo.items (
    id INT PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    amount INT NOT NULL
);
INSERT INTO demo.items VALUES (1, 'apple', 10), (2, 'banana', 20), (3, 'cherry', 30);
SQL
    done
    if [[ "$scenario" == inconsistent ]]; then
        sql tidb <<'SQL'
UPDATE demo.items SET amount = 99 WHERE id = 2;
DELETE FROM demo.items WHERE id = 3;
INSERT INTO demo.items VALUES (4, 'date', 40);
SQL
    fi
    cat > "$case_dir/config.toml" <<TOML
check-thread-count = 1
export-fix-sql = true
check-struct-only = false
[data-sources.mysql]
    host = "127.0.0.1"
    port = $mysql_port
    user = "root"
    password = ""
[data-sources.tidb]
    host = "127.0.0.1"
    port = $tidb_port
    user = "root"
    password = ""
[task]
    output-dir = "./output"
    source-instances = ["mysql"]
    target-instance = "tidb"
    target-check-tables = ["demo.items"]
TOML
    (cd "$case_dir" && "$binary" --config=config.toml) > "$case_dir/console.log" 2>&1 || rc=$?
    cat "$case_dir/console.log"
    if ! verify_report "$scenario" "$case_dir/output/summary.txt" "$rc"; then
        echo "Unexpected $scenario result (tool exit $rc); inspect $case_dir" >&2
        return 1
    fi
    cat "$case_dir/output/summary.txt"
    printf 'PASS: %s\n' "$scenario" | tee "$case_dir/result.txt"
}

main() {
    local scenario=${1:-all} base native version archive download_dir
    if [[ $# -gt 1 ]]; then usage >&2; return 2; fi
    case "$scenario" in
        all|consistent|inconsistent) ;;
        -h|--help) usage; return 0 ;;
        *) usage >&2; return 2 ;;
    esac
    for dependency in docker curl tar awk; do
        command -v "$dependency" >/dev/null || { echo "Missing: $dependency" >&2; return 1; }
    done
    docker info >/dev/null
    # Local Docker is required: the native inspector connects to published localhost ports.
    native=$(platform "$(uname -s)" "$(uname -m)")
    version=${SYNC_DIFF_VERSION:-v9.0.0-beta.2.pre-nightly}
    [[ "$version" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo 'Invalid SYNC_DIFF_VERSION' >&2; return 2; }
    base=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    mkdir -p "$base/results" "$base/.cache"
    run_dir=$(mktemp -d "$base/results/run-XXXXXXXX")
    mysql_id=''
    tidb_id=''
    network_id=''
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    download_dir="$base/.cache/$version-$native"
    binary="$download_dir/sync_diff_inspector"
    if [[ ! -x "$binary" ]]; then
        mkdir -p "$download_dir"
        archive="$run_dir/tool.tar.gz"
        curl --fail --location --retry 3 --connect-timeout 15 --max-time 600 \
            "https://tiup-mirrors.pingcap.com/sync-diff-inspector-$version-$native.tar.gz" -o "$archive"
        tar -xzf "$archive" -C "$download_dir"
        [[ -x "$binary" ]] || { echo "Binary missing from archive" >&2; return 1; }
        rm "$archive"
    fi
    "$binary" --version > "$run_dir/version.txt" 2>&1
    network_id=$(docker network create "sync-diff-${run_dir##*/}")
    mysql_id=$(docker run -d --network "$network_id" \
        -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MYSQL_ROOT_HOST=% \
        -p 127.0.0.1::3306 "${MYSQL_IMAGE:-mysql:8.4}")
    tidb_id=$(docker run -d --network "$network_id" --network-alias tidb -p 127.0.0.1::4000 "${TIDB_IMAGE:-pingcap/tidb:v8.5.3}" \
        --store=unistore --path=/tmp/tidb --host=0.0.0.0)
    mysql_port=$(docker port "$mysql_id" 3306/tcp | awk -F: '{print $NF}')
    tidb_port=$(docker port "$tidb_id" 4000/tcp | awk -F: '{print $NF}')
    wait_ready mysql
    wait_ready tidb
    if [[ "$scenario" == all ]]; then
        run_case consistent
        run_case inconsistent
    else
        run_case "$scenario"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
