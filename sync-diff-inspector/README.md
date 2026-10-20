# sync-diff-inspector Data Consistency Demo

Use Bash to start separate MySQL and TiDB Docker containers, create `demo.items` in both databases, and run sync-diff-inspector on the host. The script writes test data directly to both databases without configuring a data replication service.

## Running the Demo

Requires Bash 3.2+, a running local Docker Engine or Docker Desktop, curl, tar, awk, and network access to Docker Hub and the PingCAP mirror. A local MySQL client, TiUP, and Docker Compose are not required; SQL runs through the client inside the MySQL container. Remote Docker daemons are not supported.

```bash
# Run from the repository root; both scenarios run by default
bash sync-diff-inspector/demo.sh

# Run each scenario separately
bash sync-diff-inspector/demo.sh consistent
bash sync-diff-inspector/demo.sh inconsistent
```

Each run creates two containers and a dedicated network. Database ports are assigned dynamically and bound only to `127.0.0.1`. On completion, error, or interruption, the script automatically removes the containers, anonymous volumes, and network created for that run, while retaining reports and logs. The `all` mode recreates the tables for each scenario in turn, using the same pair of containers.

TiDB uses `unistore`, a single-process test storage engine that does not require PD or TiKV. This is not a production deployment configuration. Empty passwords are used only for this isolated demo.

## The Two Results

Both databases start with identical data:

| id | name | amount |
| --- | --- | --- |
| 1 | apple | 10 |
| 2 | banana | 20 |
| 3 | cherry | 30 |

- `consistent`: Verifies that the table schemas and data match, then prints `PASS: consistent`.
- `inconsistent`: Changes only TiDB: sets amount to 99 for id=2, deletes id=3, and inserts `(4, 'date', 40)`. The schemas still match and both tables contain 3 rows, but the data differences are `+2/-2`. The script prints `PASS: inconsistent`. The modified row replaces an old value, with one additional missing row and one extra row.

The script returns 0 when the **expected result is successfully verified** for either scenario. It returns a nonzero status if downloading, startup, connection, or validation fails, or if the result differs from expectations. The tool's own exit code for mismatched data does not by itself determine whether the demo fails: the script also strictly checks the table name, `succeed`, schema equality, difference counts, and row counts in the report to avoid treating errors or skipped checks as success.

Each run creates a separate directory to avoid reusing old checkpoints:

```text
sync-diff-inspector/results/run-XXXXXXXX/
  version.txt
  <container-id>.log
  consistent/                  # or inconsistent/
    config.toml
    console.log
    result.txt
    output/
      summary.txt              # Original consistency report
      sync_diff.log
      fix-on-tidb/              # Repair SQL generated for mismatched data
```

Repair SQL is generated but never executed automatically. Reports and the download cache are ignored by Git.

## Automatic Downloads and Versions

The script uses `uname -s` and `uname -m` to select Linux/macOS and amd64/arm64 automatically, including the x86_64/aarch64 aliases. Other operating systems or architectures produce an explicit error. The default URL format is:

```text
https://tiup-mirrors.pingcap.com/sync-diff-inspector-v9.0.0-beta.2.pre-nightly-${os}-${arch}.tar.gz
```

For example, Linux ARM64 automatically uses:

```text
https://tiup-mirrors.pingcap.com/sync-diff-inspector-v9.0.0-beta.2.pre-nightly-linux-arm64.tar.gz
```

Downloads are cached in `.cache/<version>-<os>-<arch>/` and reused on subsequent runs. The default images are `mysql:8.4` for MySQL and `pingcap/tidb:v8.5.3` for TiDB. You can override the versions; both the images and the tool version must support the current platform:

```bash
SYNC_DIFF_VERSION=v9.0.0-beta.2.pre-nightly \
MYSQL_IMAGE=mysql:8.4 TIDB_IMAGE=pingcap/tidb:v8.5.3 \
bash sync-diff-inspector/demo.sh all
```

Nightly builds may change, but the cache does not refresh automatically. Delete the corresponding cache directory to refresh it. Other versions may use a different report format, causing strict validation to fail; inspect the original report in that case.

## Development Validation

The repository uses Bats to test platform detection and result validation in Bash. The real Docker demo provides end-to-end validation:

```bash
bats sync-diff-inspector/tests
shellcheck sync-diff-inspector/demo.sh
bash sync-diff-inspector/demo.sh all
```

Reference: [Official PingCAP sync-diff-inspector documentation](https://docs.pingcap.com/zh/tidb/stable/sync-diff-inspector-overview/).

During development, both scenarios passed on macOS ARM64 with MySQL 8.4 and a locally available `pingcap/tidb:latest` image (image digest: `sha256:49159e21bdb8671cca48394ab4b6dc4e92527a775d24daf5a4b4c8d6f175a9fe`). End-to-end validation with the default `v8.5.3` image was not completed because the download was slow. The download URL and platform mapping were verified for Linux, but the demo has not yet been run on a Linux host. To reproduce the validated run:

```bash
TIDB_IMAGE=pingcap/tidb:latest bash sync-diff-inspector/demo.sh all
```

## Running GitHub Actions Manually

Workflow file: [`sync-diff-inspector.yml`](../.github/workflows/sync-diff-inspector.yml).

After merging the workflow into the default branch, trigger it manually from **Actions → Sync Diff Inspector Demo → Run workflow** in the GitHub repository. Each run executes `consistent` and `inconsistent` on two separate Ubuntu runners. A failure in one scenario does not cancel the other.

The **Print summary and sync-diff log** step in each job uses `cat` to print the complete `summary.txt` and `sync_diff.log` generated for that scenario, grouped by file. For the `inconsistent` scenario, **Print fix-on-target files** also prints the complete contents of all files under `output/fix-on-target/`, grouped by file. These steps run even if the comparison step fails. If reports or fix files are missing, they display a warning while preserving the original comparison failure status. Each job has a 20-minute timeout.

You can also trigger the workflow manually with the GitHub CLI:

```bash
gh workflow run sync-diff-inspector.yml
```

See the [official GitHub documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) for trigger conditions and default branch requirements.
