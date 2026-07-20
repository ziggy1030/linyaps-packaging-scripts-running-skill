> **[English](README.md)** | 中文

# linyaps 便捷打包任務執行器

[linyaps](https://www.linyaps.org.cn/)（琥珀）打包腳本的自動化任務編排工具。從 **JSON** 或 **CSV** 文件讀取任務定義，按 `type` 分派到對應子 SKILL：**binary** 任務使用 `pak_linyaps.sh` 執行已適配項目打包；**source** 任務使用 `ll-builder build` + `ll-builder export` 執行源碼編譯打包。

## 目錄

- [前置條件](#前置條件)
- [架構概述](#架構概述)
- [項目結構](#項目結構)
- [快速開始](#快速開始)
- [任務文件格式](#任務文件格式)
  - [JSON 格式](#json-格式)
  - [CSV 格式](#csv-格式)
- [任務類型](#任務類型)
  - [Binary（預設）](#binary預設)
  - [Source（源碼）](#source源碼)
- [命令行參考](#命令行參考)
  - [csv_to_json.sh](#csv_to_jsonsh)
- [執行流程](#執行流程)
- [架構驗證](#架構驗證)
- [疑難排解](#疑難排解)
- [注意事項](#注意事項)

---

## 前置條件

| 依賴 | 用途 |
|------|------|
| `bash` ≥ 4.0 | 腳本執行 |
| `python3` | JSON 解析、CSV 轉換、架構驗證 |
| `curl` | 下載上游資源包 |
| `jq`（可選） | 人類可讀的 JSON 查看 |
| `ll-builder` | 僅 source 類型任務需要 |
| `python3-ruamel.yaml` | Source 任務：linglong.yaml 更新 |
| `python3-yaml` | Source 任務：YAML 驗證 |

## 架構概述

```
用戶任務 (JSON/CSV)
    │
    ▼
┌─────────────────────────────────────┐
│  agents/linyaps-packaging-runner    │  ← Agent 入口（分派邏輯）
│  ├─ 讀取 agent-config.json          │
│  ├─ 按 type 分組任務                │
│  └─ 分派到子 SKILL                  │
└──────────┬──────────────────────────┘
       type│                    type
    ┌──────┴──────┐      ┌──────┴──────┐
    │ binary      │      │ source      │
    │ (或未指定)   │      │             │
    ▼             ▼      ▼             ▼
┌──────────────────┐ ┌──────────────────────┐
│ linglong-binary- │ │ linglong-source-     │
│ runner           │ │ updater              │
│                  │ │                      │
│ pak_linyaps.sh   │ │ ll-builder build     │
│                  │ │ ll-builder export    │
└──────────────────┘ └──────────────────────┘
```

## 項目結構

```
.
├── agents/
│   └── linyaps-packaging-runner.agent.md   # Agent 入口
├── agent-config.json                       # 全局配置
├── scripts/
│   ├── common.sh                           # 共享庫（14 個函數）
│   ├── csv_to_json.sh                      # CSV 轉 JSON & 統一入口
│   ├── query_upstream.sh                   # 上游信息查詢
│   ├── status_upload.sh                    # 產物上傳
│   └── check-agent-status.sh               # Agent 健康檢查
├── skills/
│   ├── config/
│   │   └── arch_mapping.json               # URL 架構關鍵字 → linyaps arch
│   ├── linglong-binary-runner/             # Binary 打包子 SKILL
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── run_tasks.sh                # Binary 任務執行器
│   │       └── validate_projects.sh        # 前置檢測
│   └── linglong-source-updater/            # Source 編譯子 SKILL
│       ├── SKILL.md
│       ├── scripts/
│       │   ├── run_tasks.sh                # Source 任務執行器（6 步驟）
│       │   ├── download-and-checksum.sh    # 下載 + sha256 + 分析
│       │   ├── update-linglong-yaml.py     # 插入 sources/build 規則
│       │   └── validate-linglong-yaml.py   # 雙模式 YAML 驗證器
│       └── references/
│           └── manifests-for-yaml.md       # linglong.yaml 字段規範
├── for-multica/
│   ├── agent.md                            # Multica 平台適配文檔
│   └── agent-config.json                   # Multica 配置
├── example/                                # 範例項目 & 生成器
├── task-example.json                       # JSON 範例（binary + source）
└── REFACTOR-PLAN.md                        # 架構設計文檔
```

### 關鍵文件說明

| 文件 | 說明 |
|------|------|
| `agents/linyaps-packaging-runner.agent.md` | **Agent 入口** — 讀取配置、按 `type` 分組任務、分派到子 SKILL |
| `agent-config.json` | 全局配置：`projects_root`、`output_dir`、`build_tmp_dir`、`src_dir` |
| `scripts/csv_to_json.sh` | **統一入口** — 接受 CSV 或 JSON，轉換後觸發 Agent 分派 |
| `scripts/common.sh` | 所有子 SKILL 共享的函數庫（顏色輸出、parse_json、下載、架構驗證等） |
| `skills/linglong-binary-runner/scripts/run_tasks.sh` | **Binary 執行器** — 下載 → 架構驗證 → 執行 `pak_linyaps.sh` |
| `skills/linglong-source-updater/scripts/run_tasks.sh` | **Source 執行器** — 6 步驟管線（驗證 → 下載校驗 → 更新 YAML → 構建 → 導出） |
| `skills/config/arch_mapping.json` | URL 架構關鍵字（`amd64`、`x64`、`aarch64`）映射到 linyaps 架構（`x86_64`、`arm64`） |
| `task-example.json` | JSON 任務文件範例，包含 binary 和 source 兩種類型 |

---

## 快速開始

### 使用 CSV 文件

```bash
# 1. 準備 CSV 文件，表頭為：记录ID,包名,架构,版本,网站地址,下载地址

# 2. 預覽生成的 JSON（dry-run 模式）
./scripts/csv_to_json.sh my-tasks.csv --dry-run

# 3. 使用已適配的項目執行打包
./scripts/csv_to_json.sh my-tasks.csv \
  --projects_root=/path/to/adapted/projects
```

### 使用 JSON 文件

```bash
# 直接使用 JSON 任務文件（包含 type=binary 或 type=source 任務）
./scripts/csv_to_json.sh task-example.json
```

> **注意：** 使用 `csv_to_json.sh` 作為入口保持向後兼容 — 它會自動識別 JSON 文件並傳遞給 Agent 分派。

---

## 任務文件格式

### JSON 格式

JSON 任務文件包含 `global` 配置區塊和 `tasks` 數組：

```json
{
  "global": {
    "projects_root": "/path/to/projects",
    "output_dir": "./output",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  },
  "tasks": [
    {
      "pkgName": "com.opera.browser",
      "type": "binary",
      "src_url": "https://download3.operacdn.com/pub/opera/desktop/130.0.5847.92/linux/opera-stable_130.0.5847.92_amd64.deb",
      "arch": "x86_64",
      "orig_version": "130.0.5847.92"
    },
    {
      "pkgName": "com.example.sourceapp",
      "type": "source",
      "src_url": "https://example.com/sourceapp-2.0.tar.gz",
      "arch": "x86_64",
      "orig_version": "2.0",
      "kind": "archive",
      "name": "src"
    }
  ]
}
```

#### 全局配置

| 欄位 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `projects_root` | **是** | — | 已適配便捷打包的項目根目錄 |
| `output_dir` | 否 | `./output` | 構建輸出目錄 |
| `build_tmp_dir` | 否 | *（自動生成）* | 構建緩存目錄 |
| `src_dir` | 否 | `./src` | 下載的上游資源目錄 |

#### 任務條目欄位

| 欄位 | 必填 | 說明 |
|------|------|------|
| `pkgName` | **是** | 包名，用於定位項目目錄（如 `com.opera.browser`） |
| `type` | 否 | 任務類型：`binary`（預設）或 `source` |
| `src_url` | **是** | 上游資源下載地址 |
| `arch` | **是** | 目標架構：`x86_64` 或 `arm64` |
| `orig_version` | 否 | 上游版本號；為空時從 `src_url` 自動提取 |
| `kind` | Source 專用 | 源碼類型：`archive`、`git`、`file`、`dsc`（預設：`archive`） |
| `name` | Source 專用 | linglong.yaml 中 sources 條目的 name 字段（預設：`src`） |

**可選：版本號提取模式**（頂層 `version_extract_examples`）：

當 `orig_version` 為空時，腳本會嘗試匹配這些正則模式從 `src_url` 中自動提取版本號。詳見 `agent-config.json` 範例。

---

### CSV 格式

CSV 文件必須使用 UTF-8 編碼，並包含以下表頭行：

```csv
记录ID,包名,架构,版本,网站地址,下载地址
```

#### 欄位映射

| CSV 欄位 | JSON 欄位 | 必填 | 說明 |
|----------|-----------|------|------|
| `记录ID` | *（忽略）* | 否 | 參考 ID，不使用 |
| `包名` | `pkgName` | **是** | 包名，用於項目目錄查找 |
| `架构` | `arch` | **是** | 目標架構（`x86_64` / `arm64`） |
| `版本` | `orig_version` | 否 | 上游版本號；為空時從 URL 自動提取 |
| `网站地址` | *（忽略）* | 否 | 項目主頁，不使用 |
| `下载地址` | `src_url` | **是** | 上游資源下載地址 |

> **注意：** CSV 任務預設為 `type=binary`。如需 source 類型，請使用 JSON 格式並設定 `"type": "source"`。

#### 數據清理

轉換器會自動處理以下情況：
- **空白字符修剪**：移除所有欄位的前導/尾隨空格和 tab 字符
- **表頭別名**：同時支持簡體（下载地址）和繁體（下載地址）中文表頭
- **行跳過**：缺少必要欄位的行會被靜默跳過

#### CSV 的全局配置

由於 CSV 文件沒有 `global` 區塊，配置通過以下方式提供：

1. **命令行參數**（優先級最高）：
   ```bash
   ./scripts/csv_to_json.sh tasks.csv \
     --projects_root=/path/to/projects \
     --output_dir=./output
   ```

2. **JSON 配置文件**（`--config`）：
   ```bash
   ./scripts/csv_to_json.sh tasks.csv --config=global_config.json
   ```

3. **預設值**（優先級最低）：
   | 參數 | 預設值 |
   |------|--------|
   | `projects_root` | `./projects` |
   | `output_dir` | `./output` |
   | `build_tmp_dir` | *（自動生成）* |
   | `src_dir` | `./src` |

---

## 任務類型

### Binary（預設）

- **入口**：`pak_linyaps.sh`
- **範圍**：已適配打包腳本的項目（目錄下包含 `pak_linyaps.sh` + `templates/linglong.yaml`）
- **子 SKILL**：`linglong-binary-runner`
- **流程**：下載 → 架構驗證 → 定位項目 → 執行 `pak_linyaps.sh`
- **約束**：嚴禁改寫 `linglong.yaml` 或直接調用 `ll-builder`

### Source（源碼）

- **入口**：`ll-builder build` + `ll-builder export`
- **範圍**：含 `linglong.yaml` 但無 `pak_linyaps.sh` 的源碼項目
- **子 SKILL**：`linglong-source-updater`
- **流程**：6 步驟管線 — 驗證 → 下載校驗 → 更新 YAML → 驗證輸出 → 構建 → 導出
- **約束**：輸入的 `linglong.yaml` 必須通過預驗證（無 sources 段）；build 規則必須使用 `${PREFIX}` 路徑

---

## 命令行參考

### csv_to_json.sh

**統一入口** — 接受 CSV 和 JSON 文件，轉換 CSV 為 JSON，觸發 Agent 分派流程。

```
./scripts/csv_to_json.sh <task.csv|task.json> [options]
```

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `--projects_root=<path>` | `./projects` | 已適配便捷打包的項目根目錄 |
| `--output_dir=<path>` | `./output` | 構建輸出目錄 |
| `--build_tmp_dir=<path>` | *（自動）* | 構建緩存目錄 |
| `--src_dir=<path>` | `./src` | 下載的上游資源目錄 |
| `--config=<file.json>` | *（無）* | 提供 `global` 配置的 JSON 配置文件 |
| `--output=<file.json>` | *（自動）* | 生成的 JSON 任務文件輸出路徑 |
| `--dry-run` | `false` | 僅生成 JSON，不執行打包 |
| `--help` | — | 顯示使用說明 |

**按文件類型的行為：**
- **CSV 輸入** → 轉換為 JSON → Agent 按 type 分派
- **JSON 輸入** → 直接傳遞給 Agent 分派

---

## 執行流程

```
┌──────────────────────────────────────────────────────────────┐
│  1. 載入配置                                                 │
│     agent-config.json → 全局設定 + 版本提取模式               │
├──────────────────────────────────────────────────────────────┤
│  2. 解析與初始化                                             │
│     CSV → csv_to_json.sh → JSON                              │
│     JSON → 直接使用                                           │
│     創建: src_dir, output_dir, build_tmp_dir                 │
├──────────────────────────────────────────────────────────────┤
│  3. 按類型分派（Agent 階段）                                   │
│     ┌──────────────────────────────────────────────────┐     │
│     │ 按 tasks[].type 分組（預設 "binary"）              │     │
│     │ 為每組寫入子任務 JSON                               │     │
│     │ 調用子 SKILL：                                     │     │
│     │   binary → linglong-binary-runner                  │     │
│     │   source → linglong-source-updater                 │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  4. Binary 執行（逐任務）                                     │
│     ┌──────────────────────────────────────────────────┐     │
│     │ a. 從 URL 提取版本號（如未提供）                  │     │
│     │ b. 架構驗證（URL vs 宣告架構）                    │     │
│     │ c. 下載上游資源                                   │     │
│     │ d. 定位項目（CI_ll_<pkgName> / <pkgName>）       │     │
│     │ e. 檢測 --build_tmp_dir 支援                     │     │
│     │ f. 執行 pak_linyaps.sh                           │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  5. Source 執行（6 步驟逐任務）                               │
│     ┌──────────────────────────────────────────────────┐     │
│     │ S-1: 驗證輸入 linglong.yaml（無 sources）         │     │
│     │ S-2: 下載 + sha256 + 目錄分析                    │     │
│     │ S-3: 插入 sources + 修正 build 規則              │     │
│     │ S-4: 驗證輸出 linglong.yaml（有 sources）         │     │
│     │ S-5: ll-builder build                            │     │
│     │ S-6: ll-builder export → 移動 .layer 到 output   │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  6. 輸出結果統計                                            │
│     總計 / 成功 / 失敗數 + 每個任務詳情                      │
└──────────────────────────────────────────────────────────────┘
```

每個任務會在 `<output_dir>/<pkgName>.log` 生成日誌文件。

---

## 架構驗證

在下載之前，腳本會驗證任務中宣告的架構是否與下載 URL 中隱含的架構匹配。

### 工作原理

1. **Token 匹配**：掃描 URL 中來自 `arch_mapping.json` 的已知架構關鍵字
   - `amd64`、`x64`、`x86_64`、`intel` → `x86_64`
   - `arm64`、`aarch64`、`armv8` → `arm64`
   - `i386`、`i686`、`armhf`、`armv7` → 不支援（觸發不匹配）

2. **正則表達式匹配**：應用特定 URL 模式規則
   - `linux-deb-x64/stable` → `x86_64`（VS Code 風格）
   - `_amd64.deb` → `x86_64`（Debian 套件後綴）

3. **結果處理**：

   | 結果 | 行為 |
   |------|------|
   | **MATCH** | ✅ 繼續執行打包 |
   | **MISMATCH** | ❌ 跳過任務，計入失敗統計 |
   | **UNKNOWN** | ⚠️ 輸出 LLM 分析提示，繼續執行 |

### 範例

```
[OK] 架構驗證通過: URL 含架構(x86_64) → 宣告 arch(x86_64) ✓
[ERROR] 架構不匹配: URL 含架構(x86_64)，但宣告 arch 為 arm64
```

---

## 疑難排解

### "找不到項目目錄"

腳本在 `projects_root` 下按以下順序查找項目目錄：
1. `CI_ll_<pkgName>/pak_linyaps.sh`
2. `<pkgName>/pak_linyaps.sh`
3. 模糊匹配：任何包含 `<pkgName>` 且含有 `pak_linyaps.sh` 的目錄

**解決方案**：確保已適配的項目位於 `projects_root` 中，並遵循 `CI_ll_<pkgName>` 命名慣例。

### "架構不匹配"

URL 中包含的架構關鍵字與宣告的 `arch` 欄位矛盾。

**解決方案**：驗證任務文件中的 `arch` 欄位是否與實際套件架構匹配。查看 `skills/config/arch_mapping.json` 了解支援的映射。

### "無法從 URL 提取版本號"

`orig_version` 欄位為空，且 URL 不匹配任何已知的版本模式。

**解決方案**：在任務文件中顯式設定 `orig_version`，或在 `agent-config.json` 的 `version_extract_examples` 中添加新模式。

### "CSV 缺少必要欄位"

CSV 文件缺少以下欄位之一：`包名`、`下载地址`、`架构`。

**解決方案**：確保 CSV 文件包含帶有所有必要欄位的表頭行。

### 下載重定向 URL 失敗

某些 URL（如 VS Code 的 `update.code.visualstudio.com/latest/...`）需要跟隨重定向。

**解決方案**：腳本通過 `curl -L` 自動處理重定向。如仍有問題，請預先下載文件並使用直接 URL。

---

## 注意事項

- **`--build_tmp_dir` 支援並非通用**：腳本通過搜索 `build_tmp_dir` 關鍵字自動檢測項目是否支援此參數。如不支援，該參數會被靜默省略。
- **執行權限**：確保 `pak_linyaps.sh` 腳本具有執行權限（`chmod +x`）。
- **UTF-8 編碼**：CSV 文件必須使用 UTF-8 編碼。同時支持簡體和繁體中文表頭。
- **順序執行**：任務按順序執行。如需並行執行，請拆分任務文件並使用不同的 `output_dir` 和 `build_tmp_dir` 值運行多個實例。
- **向後兼容**：`csv_to_json.sh` 仍是統一入口，透明處理 CSV 和 JSON 文件。
- **符號連結設置**：將此倉庫用作 opencode skill 時，需按 `REFACTOR-PLAN.md` 中的說明設置 `.opencode/` 符號連結。
