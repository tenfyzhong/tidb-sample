#!/usr/bin/env bats
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../demo.sh"
}
@test "native download platform mapping" {
    for pair in 'Linux aarch64 linux-arm64' 'Linux x86_64 linux-amd64' 'Darwin arm64 darwin-arm64' 'Darwin x86_64 darwin-amd64'; do
        read -r os arch expected <<< "$pair"
        run bash -c 'source "$1"; platform "$2" "$3"' _ "$SCRIPT" "$os" "$arch"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
}
@test "unsupported platforms fail" {
    run bash -c 'source "$1"; platform Linux riscv64' _ "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *Unsupported* ]]
}
@test "consistent report requires completed equal table" {
    printf '| `demo`.`items` | 3 | 3 |\n' > "$BATS_TEST_TMPDIR/report"
    run bash -c 'source "$1"; verify_report consistent "$2" 0' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
    [ "$status" -eq 0 ]
}
@test "inconsistent report requires successful comparison and exact row differences" {
    printf '| `demo`.`items` | succeed | true | +2/-2 | 3 | 3 |\n' > "$BATS_TEST_TMPDIR/report"
    run bash -c 'source "$1"; verify_report inconsistent "$2" 0' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
    [ "$status" -eq 0 ]
}
@test "errors and skipped checks are not inconsistencies" {
    for row in '| `demo`.`items` | failed | true | +2/-2 | 3 | 3 |' '| `demo`.`items` | skipped | true | +2/-2 | 3 | 3 |' ''; do
        printf '%s\n' "$row" > "$BATS_TEST_TMPDIR/report"
        run bash -c 'source "$1"; verify_report inconsistent "$2" 0' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
        [ "$status" -ne 0 ]
    done
}
@test "nonzero tool exit fails even with an equal report" {
    printf '| `demo`.`items` | 3 | 3 |\n' > "$BATS_TEST_TMPDIR/report"
    run bash -c 'source "$1"; verify_report consistent "$2" 1' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
    [ "$status" -ne 0 ]
}
@test "invalid scenario is rejected before Docker is used" {
    run bash "$SCRIPT" typo
    [ "$status" -eq 2 ]
    [[ "$output" == *Usage* ]]
}
@test "mismatch exit 1 still requires a valid report" {
    printf '| `demo`.`items` | succeed | true | +2/-2 | 3 | 3 |\n' > "$BATS_TEST_TMPDIR/report"
    run bash -c 'source "$1"; verify_report inconsistent "$2" 1' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; verify_report inconsistent "$2" 2' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
    [ "$status" -ne 0 ]
}
@test "wrong table, structure mismatch, or unexpected counts fail" {
    for row in '| `other`.`items` | succeed | true | +2/-2 | 3 | 3 |' '| `demo`.`items` | succeed | false | +2/-2 | 3 | 3 |' '| `demo`.`items` | succeed | true | +1/-1 | 3 | 3 |'; do
        printf '%s\n' "$row" > "$BATS_TEST_TMPDIR/report"
        run bash -c 'source "$1"; verify_report inconsistent "$2" 1' _ "$SCRIPT" "$BATS_TEST_TMPDIR/report"
        [ "$status" -ne 0 ]
    done
}
