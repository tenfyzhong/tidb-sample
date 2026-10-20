#!/usr/bin/env bats

setup() {
    local workflow="$BATS_TEST_DIRNAME/../../.github/workflows/sync-diff-inspector.yml"
    # Execute the actual repair-file step instead of duplicating its glob here.
    REPAIR_STEP=$(awk '
        /^      - name:/ {
            if (selected) exit
            selected = /Print .* files/
        }
        selected && /^        run: \|/ { body = 1; next }
        body { sub(/^          /, ""); print }
    ' "$workflow")
    [ -n "$REPAIR_STEP" ]
    cd "$BATS_TEST_TMPDIR"
    export SCENARIO=inconsistent
}

@test "workflow prints repair SQL from the configured tidb target directory" {
    local repair_dir="sync-diff-inspector/results/run-example/inconsistent/output/fix-on-tidb"
    mkdir -p "$repair_dir/nested"
    printf 'DELETE FROM demo.items WHERE id = 4;\n' > "$repair_dir/delete.sql"
    printf "REPLACE INTO demo.items VALUES (2, 'banana', 20);\n" > "$repair_dir/nested/repair rows.sql"

    run bash -e -o pipefail -c "$REPAIR_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::group::$repair_dir/delete.sql"* ]]
    [[ "$output" == *"DELETE FROM demo.items WHERE id = 4;"* ]]
    [[ "$output" == *"::group::$repair_dir/nested/repair rows.sql"* ]]
    [[ "$output" == *"REPLACE INTO demo.items VALUES (2, 'banana', 20);"* ]]
    [[ "$output" != *"::warning::"* ]]
}

@test "workflow warns without failing when no repair files were generated" {
    run bash -e -o pipefail -c "$REPAIR_STEP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::No "* ]]
    [[ "$output" != *"::group::"* ]]
}
