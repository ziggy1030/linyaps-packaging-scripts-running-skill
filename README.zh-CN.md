> **[English](README.md)** | 中文

# linyaps 便捷打包任務執行器

[linyaps](https://www.linyaps.org.cn/)（琥珀）便捷打包腳本的自動化任務編排工具。支持從 **JSON** 或 **CSV** 文件讀取任務定義，自動下載上游資源、定位已適配便捷打包的項目，並批量執行 `pak_linyaps.sh` 打包命令。

## 目錄

- [前置條件](#前置條件)
- [項目結構](#項目結構)
- [快速開始](#快速開始)
- [任務文件格式](#任務文件格式)
  - [JSON 格式](#json-格式)
  - [CSV 格式](#csv-格式)
- [命令行參考](#命令行參考)
  - [csv_to_json.sh](#csv_to_jsonsh)
  - [run_tasks.sh](#run_taskssh)
- [執行流程](#執行流程)
- [架構驗證](#架構驗證)
- [演示文件](#演示文件)
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

## 項目結構

```
.
├── SKILL.md                  # AI 代理集成的 Skill 定義文件
├── README.md                 # 本說明文件
├── task-example.json         # JSON 任務文件範例
├── arch_mapping.json         # 架構關鍵字 → linyaps arch 映射表
├── scripts/
│   ├── csv_to_json.sh        # CSV 轉 JSON 轉換器 & 統一入口
│   └── run_tasks.sh          # 核心任務執行器（基於 JSON）
└── demo-files/
    ├── taskInfo.example.csv               # CSV 範例（2 個任務）
    ├── Upstream_20260528133849.csv        # 真實 CSV 數據（9 個任務）
    ├── CI_ll_com.opera.browser/           # 演示：Opera 打包項目
    │   ├── pak_linyaps.sh
    │   ├── scripts/
    │   └── templates/
    └── CI_ll_com.visualstudio.code/       # 演示：VS Code 打包項目
        ├── pak_linyaps.sh
        ├── src/
        └── templates/
```

### 關鍵文件說明

| 文件 | 說明 |
|------|------|
| `scripts/csv_to_json.sh` | **統一入口** — 同時接受 CSV 和 JSON 任務文件。將 CSV 轉換為 JSON 後委派給 `run_tasks.sh` 執行。 |
| `scripts/run_tasks.sh` | 核心執行器 — 解析 JSON 任務、下載資源、驗證架構，並為每個任務執行 `pak_linyaps.sh`。 |
| `arch_mapping.json` | 將 URL 中的架構關鍵字（如 `amd64`、`x64`、`aarch64`）映射到 linyaps 架構標識符（`x86_64`、`arm64`）。 |
| `task-example.json` | JSON 任務文件範例，包含 `version_extract_examples` 用於自動版本號提取。 |

---

## 快速開始

### 使用 CSV 文件

```bash
# 1. 準備 CSV 文件，表頭為：记录ID,包名,架构,版本,网站地址,下载地址

# 2. 預覽生成的 JSON（dry-run 模式）
./scripts/csv_to_json.sh demo-files/taskInfo.example.csv --dry-run

# 3. 使用已適配的項目執行打包
./scripts/csv_to_json.sh demo-files/taskInfo.example.csv \
  --projects_root=/path/to/adapted/projects
```

### 使用 JSON 文件

```bash
# 直接使用 JSON 任務文件執行
./scripts/run_tasks.sh task-example.json
```

---

## 任務文件格式

### JSON 格式

JSON 任務文件包含 `global` 配置區塊和 `tasks` 數組：

```json
{
  "global": {
    "projects_root": "/path/to/adapted/projects",
    "output_dir": "./output",
    "build_tmp_dir": "",
    "src_dir": "./src"
  },
  "tasks": [
    {
      "pkgName": "com.opera.browser",
      "src_url": "https://download3.operacdn.com/pub/opera/desktop/130.0.5847.92/linux/opera-stable_130.0.5847.92_amd64.deb",
      "arch": "x86_64",
      "orig_version": "130.0.5847.92"
    }
  ]
}
```

#### 欄位說明

**全局配置：**

| 欄位 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `projects_root` | **是** | — | 已適配便捷打包的項目根目錄 |
| `output_dir` | 否 | `./output` | 構建輸出目錄 |
| `build_tmp_dir` | 否 | *（自動生成）* | 構建緩存目錄；為空時自動創建臨時目錄 |
| `src_dir` | 否 | `./src` | 下載的上游資源目錄 |

**任務條目：**

| 欄位 | 必填 | 說明 |
|------|------|------|
| `pkgName` | **是** | 包名，用於定位匹配的項目目錄（如 `com.opera.browser`） |
| `src_url` | **是** | 上游資源下載地址 |
| `arch` | **是** | 目標架構：`x86_64` 或 `arm64` |
| `orig_version` | 否 | 上游版本號；為空時從 `src_url` 自動提取 |

**可選：版本號提取模式**（頂層 `version_extract_examples`）：

當 `orig_version` 為空時，腳本會嘗試匹配這些模式從 `src_url` 中自動提取版本號。詳見 `task-example.json` 範例。

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

#### CSV 範例

```csv
记录ID,包名,架构,版本,网站地址,下载地址
1cea051c-...,com.jetbrains.www.pycharm,x86_64,2026.1.2,https://data.services.jetbrains.com/...,https://rustfsadmin.../com.jetbrains.www.pycharm_x86_64_2026.1.2.tar.gz
c7c2946f-...,org.mozilla.firefox-nal,x86_64,151.0.2,https://www.firefox.com/zh-CN/,https://rustfsadmin.../org.mozilla.firefox-nal_x86_64_151.0.2.tar.xz
```

#### 數據清理

轉換器會自動處理以下情況：
- **空白字符修剪**：移除所有欄位的前導/尾隨空格和 tab 字符
- **表頭別名**：同時支持簡體（下载地址）和繁體（下載地址）中文表頭
- **行跳過**：缺少必要欄位（`包名`、`下载地址`、`架构`）的行會被靜默跳過

#### CSV 的全局配置

由於 CSV 文件沒有 `global` 區塊，配置通過以下方式提供：

1. **命令行參數**（優先級最高）：
   ```bash
   ./scripts/csv_to_json.sh tasks.csv \
     --projects_root=/path/to/projects \
     --output_dir=./output \
     --src_dir=./src
   ```

2. **JSON 配置文件**（`--config`）：
   ```bash
   ./scripts/csv_to_json.sh tasks.csv --config=global_config.json
   ```
   其中 `global_config.json` 僅包含 `global` 區塊：
   ```json
   {
     "global": {
       "projects_root": "/path/to/projects",
       "output_dir": "./output",
       "build_tmp_dir": "",
       "src_dir": "./src"
     }
   }
   ```

3. **預設值**（優先級最低）：
   | 參數 | 預設值 |
   |------|--------|
   | `projects_root` | `./projects` |
   | `output_dir` | `./output` |
   | `build_tmp_dir` | *（自動生成臨時目錄）* |
   | `src_dir` | `./src` |

---

## 命令行參考

### csv_to_json.sh

**統一入口** — 同時接受 CSV 和 JSON 文件。

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
- **CSV 輸入** → 轉換為 JSON → 通過 `run_tasks.sh` 執行
- **JSON 輸入** → 直接傳遞給 `run_tasks.sh`（向後兼容）

### run_tasks.sh

**核心執行器** — 直接處理 JSON 任務文件。

```
./scripts/run_tasks.sh <task.json>
```

此腳本由 `csv_to_json.sh` 內部調用，也可單獨用於 JSON 任務文件。

---

## 執行流程

```
┌─────────────────────────────────────────────────────────────┐
│  1. 解析任務文件                                            │
│     CSV → csv_to_json.sh → JSON                             │
│     JSON → 直接使用                                          │
├─────────────────────────────────────────────────────────────┤
│  2. 初始化目錄                                              │
│     創建: src_dir, output_dir, build_tmp_dir                │
├─────────────────────────────────────────────────────────────┤
│  3. 逐個任務處理:                                           │
│     ┌───────────────────────────────────────────────────┐   │
│     │ 3a. 從 URL 提取版本號（如未提供）                  │   │
│     │ 3b. 驗證架構（URL vs 宣告架構）                    │   │
│     │ 3c. 下載上游資源到 src_dir                        │   │
│     │ 3d. 在 projects_root 中定位項目目錄               │   │
│     │     （匹配 CI_ll_<pkgName> 或 <pkgName>）         │   │
│     │ 3e. 檢測 --build_tmp_dir 支援                     │   │
│     │ 3f. 使用生成的參數執行 pak_linyaps.sh             │   │
│     └───────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│  4. 輸出結果統計                                            │
│     總計 / 成功 / 失敗數 + 每個任務詳情                      │
└─────────────────────────────────────────────────────────────┘
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

## 演示文件

`demo-files/` 目錄包含即用型範例：

### taskInfo.example.csv

包含 2 個任務的簡約 CSV：
- `com.jetbrains.www.pycharm` — PyCharm (x86_64)
- `org.mozilla.firefox-nal` — Firefox (x86_64)

### Upstream_20260528133849.csv

包含 9 個任務的真實 CSV，涵蓋瀏覽器、媒體播放器和開發工具。

### CI_ll_com.opera.browser

完整適配的 Opera 打包項目，展示預期的項目結構：
```
CI_ll_com.opera.browser/
├── pak_linyaps.sh          # 主打包腳本
├── scripts/                # 輔助腳本
│   ├── dedup_desktop_files.sh
│   ├── handle_special_paths.sh
│   └── validate_bin_nesting.sh
└── templates/
    ├── linglong.yaml       # linyaps 清單模板
    └── files_res/          # Desktop 文件、圖標等
```

### CI_ll_com.visualstudio.code

完整適配的 VS Code 打包項目，結構類似，包含 `appdata.xml`、`bash-completion` 和 `zsh` 補全。

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

**解決方案**：驗證任務文件中的 `arch` 欄位是否與實際套件架構匹配。查看 `arch_mapping.json` 了解支援的映射。

### "無法從 URL 提取版本號"

`orig_version` 欄位為空，且 URL 不匹配任何已知的版本模式。

**解決方案**：在任務文件中顯式設定 `orig_version`，或在 JSON 任務文件的 `version_extract_examples` 中添加新模式。

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
- **向後兼容**：`csv_to_json.sh` 透明處理 JSON 文件，直接傳遞給 `run_tasks.sh`，因此可作為兩種格式的統一入口。
