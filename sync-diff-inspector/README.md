# sync-diff-inspector 数据一致性示例

用 Bash 启动独立的 MySQL 和 TiDB Docker 容器，在两端创建 `demo.items`，然后在宿主机运行 sync-diff-inspector。脚本直接写入两端测试数据，不配置数据同步服务。

## 运行

需要 Bash 3.2+、本机 Docker Engine 或 Docker Desktop（已启动）、curl、tar、awk，以及访问 Docker Hub 和 PingCAP 镜像站的网络。无需本机 MySQL 客户端、TiUP 或 Docker Compose；SQL 使用 MySQL 容器内的客户端执行。远程 Docker daemon 不适用。

```bash
# 在仓库根目录运行；默认执行两种场景
bash sync-diff-inspector/demo.sh

# 分别执行
bash sync-diff-inspector/demo.sh consistent
bash sync-diff-inspector/demo.sh inconsistent
```

每次运行创建两个容器及专用网络，数据库端口随机分配且只绑定 `127.0.0.1`。完成、报错或收到中断信号后，自动删除本次创建的容器、匿名卷和网络，保留报告及日志。`all` 在同一组容器中依次重建表，分别验证两个场景。

TiDB 使用 `unistore` 单进程测试存储，不需要 PD/TiKV；这不是生产部署配置。空密码仅用于此隔离示例。

## 两种结果

两端初始数据相同：

| id | name | amount |
| --- | --- | --- |
| 1 | apple | 10 |
| 2 | banana | 20 |
| 3 | cherry | 30 |

- `consistent`：验证表结构和数据一致，输出 `PASS: consistent`。
- `inconsistent`：仅修改 TiDB：把 id=2 的 amount 改为 99，删除 id=3，新增 `(4, 'date', 40)`。表结构仍一致、两端均为 3 行，数据差异为 `+2/-2`，输出 `PASS: inconsistent`。修改一行对应替换旧值，另有一行缺失和一行多余。

两种**预期结果验证成功**时脚本均返回 0；下载、启动、连接、校验出错或结果不符合预期时返回非零。工具自身的数据不一致退出码不直接作为示例失败依据：脚本还会严格检查报告中的表名、`succeed`、结构相等、差异数量和行数，防止将错误或跳过校验视为成功。

每次执行创建独立目录，避免复用旧 checkpoint：

```text
sync-diff-inspector/results/run-XXXXXXXX/
  version.txt
  <container-id>.log
  consistent/                  # 或 inconsistent/
    config.toml
    console.log
    result.txt
    output/
      summary.txt              # 原始一致性报告
      sync_diff.log
      fix-on-tidb/             # 不一致时生成的修复 SQL
```

修复 SQL 只生成、不自动执行；报告和下载缓存已被 Git 忽略。

## 自动下载与版本

根据 `uname -s` 和 `uname -m` 自动选择 Linux/macOS、amd64/arm64（支持 x86_64/aarch64 别名）；其他系统或架构明确报错。默认 URL 格式：

```text
https://tiup-mirrors.pingcap.com/sync-diff-inspector-v9.0.0-beta.2.pre-nightly-${os}-${arch}.tar.gz
```

例如 Linux ARM64 自动使用：

```text
https://tiup-mirrors.pingcap.com/sync-diff-inspector-v9.0.0-beta.2.pre-nightly-linux-arm64.tar.gz
```

下载后缓存到 `.cache/<version>-<os>-<arch>/`，后续复用。默认 MySQL 镜像 `mysql:8.4`，TiDB 镜像 `pingcap/tidb:v8.5.3`。可以覆盖版本（镜像及工具版本必须支持当前平台）：

```bash
SYNC_DIFF_VERSION=v9.0.0-beta.2.pre-nightly \
MYSQL_IMAGE=mysql:8.4 TIDB_IMAGE=pingcap/tidb:v8.5.3 \
bash sync-diff-inspector/demo.sh all
```

nightly 内容可能更新，缓存不会自动刷新；需要刷新时删除对应缓存目录。其他版本的报告格式可能变化，严格校验会报错，此时应查看原始报告。

## 开发验证

仓库使用 Bats 测试 Bash 的平台识别及结果判断，真实 Docker 演示用于端到端验证：

```bash
bats sync-diff-inspector/tests
shellcheck sync-diff-inspector/demo.sh
bash sync-diff-inspector/demo.sh all
```

参考：[PingCAP 官方 sync-diff-inspector 文档](https://docs.pingcap.com/zh/tidb/stable/sync-diff-inspector-overview/)。

本次开发验证环境为 macOS ARM64、MySQL 8.4，使用本机已有的 `pingcap/tidb:latest`（镜像摘要 `sha256:49159e21bdb8671cca48394ab4b6dc4e92527a775d24daf5a4b4c8d6f175a9fe`）跑通两个场景。默认 `v8.5.3` 镜像因下载缓慢未完成端到端验证；Linux 平台已验证下载地址及平台映射，尚未实机运行。可复现已验证的命令：

```bash
TIDB_IMAGE=pingcap/tidb:latest bash sync-diff-inspector/demo.sh all
```

## GitHub Actions 手动运行

工作流文件：[`sync-diff-inspector.yml`](../.github/workflows/sync-diff-inspector.yml)。

将工作流合入默认分支后，在 GitHub 仓库的 **Actions → Sync Diff Inspector Demo → Run workflow** 中手动触发。每次触发都会在两个独立的 Ubuntu runner 上分别执行 `consistent` 和 `inconsistent`；一个场景失败不会取消另一个场景。

每个 Job 最后的 **Print summary and sync-diff log** 步骤使用 `cat` 输出本场景产生的完整 `summary.txt` 和 `sync_diff.log`，按文件分组展示。即使对比步骤失败也会执行；如果失败发生在报告生成前，则显示缺失文件警告，原始对比失败状态仍会保留。每个 Job 最长运行 20 分钟。

也可以用 GitHub CLI 手动触发：

```bash
gh workflow run sync-diff-inspector.yml
```

触发条件及默认分支要求参见 [GitHub 官方文档](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。
