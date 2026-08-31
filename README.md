# checkmd5 — SHA256 供应链校验中心

每日自动抓取上游软件包的 `SHA256`，供其他项目做完整性校验。

## 架构

| 文档 | 作用 | 路径 |
|---|---|---|
| **版本清单** | 唯一真实来源，声明要跟踪的软件及版本 | `versions.yaml` |
| **执行脚本** | 下载并计算哈希，生成产物 | `tools/fetch-checksums.sh` |
| **产物** | 下游消费 | `dist/checksums.sha256` + `dist/checksums.json` |
| **定时任务** | GitHub Actions 每天 02:00 UTC 自动刷新 | `.github/workflows/daily.yml` |

## 快速开始

### 本地生成

```bash
./tools/fetch-checksums.sh --update   # 刷新 dist/
./tools/fetch-checksums.sh --check    # 校验覆盖率
cat dist/checksums.sha256
```

### 更新版本

只需改 `versions.yaml`:

```yaml
packages:
  nginx:
    version: "1.31.5"   # bump
```

提交后自动触发 Workflow，或手动 `workflow_dispatch`，产物会提 PR 到 `main`。

### 下游消费

**Shell 一行校验（推荐）**:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/checkmd5/main/dist/checksums.sha256 -o /tmp/checksums.sha256
sha256sum -c /tmp/checksums.sha256 --ignore-missing --strict
```

**编程消费**:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/checkmd5/main/dist/checksums.json | jq '.packages.nginx.sha256'
```

详见 `docs/CONSUMPTION.md:1`。

## 目录结构

```
.
├── versions.yaml
├── dist/
│   ├── checksums.sha256
│   └── checksums.json
├── tools/fetch-checksums.sh
├── .github/workflows/daily.yml
├── docs/CONSUMPTION.md
└── SPEC.md
```

## 定时

- `cron: '0 2 * * *'` 每天 02:00 UTC
- 监听 `versions.yaml` 的 `push` 立即刷新
- 支持 `workflow_dispatch` 手动触发

## 安全

- `create-pull-request` PR 模式，需 Review 后合併，防投毒
- 产物可接 `cosign sign-blob` / `gpg --verify`（预留）
