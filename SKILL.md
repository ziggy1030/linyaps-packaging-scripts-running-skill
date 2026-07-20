---
name: linyaps-packaging-runner
description: '自動執行 linyaps 琥珀打包腳本。當用戶提供 JSON 或 CSV 任務文件並要求執行 linyaps 打包時使用。關鍵詞: pak_linyaps, linyaps, 琥珀, 打包, linglong, build, package, csv, json。'
argument-hint: '<task.json|task.csv>'
user-invocable: true
---

> **⛔ 腳本路徑解析規則（重要）**  
>   
> **問題**：在 multica 等平台上執行時，當前工作目錄（CWD）可能不是本 SKILL 所在目錄，導致相對路徑 `scripts/xxx.sh` 無法正確解析。  
> 
> **解決方案**——執行任何腳本前，必須先解析 SKILL_ROOT：
> 1. **SKILL_ROOT**：即本檔案（`SKILL.md`）所在的目錄。可使用 `dirname "$(realpath "$0")"` 或相對於 agent-config.json 的位置推導。
> 2. **腳本目錄結構**：所有輔助腳本統一存放在 `<SKILL_ROOT>/scripts/` 目錄下：
>    - `csv_to_json.sh` — CSV 轉 JSON 任務文件
>    - `query_upstream.sh` — 上游信息查詢（調用 n8n API）
>    - `run_tasks.sh` — 批量任務執行
>    - `status_upload.sh` — 產物上傳與狀態回報
>    - `validate_projects.sh` — 前置項目驗證
> 3. **調用規則**：在 bash 命令中調用腳本時，統一使用 `bash <SKILL_ROOT>/scripts/<script_name>.sh` 格式（即補上 SKILL_ROOT 前綴），**禁止**使用 `./scripts/xxx.sh` 或純相對路徑 `scripts/xxx.sh`，以確保不論工作目錄為何都能正確找到腳本。
> 4. **`agent-config.json`**：存放於 SKILL_ROOT 目錄（或 `for-multica/` 子目錄），以相對於 SKILL_ROOT 的路徑引用。

# linyaps 便捷打包腳本自動執行

## 用途
根據用戶提供的 JSON 任務文件，自動下載原始資源、定位已適配便捷打包的項目、生成並執行 `pak_linyaps.sh` 打包命令。

## 何時使用
- 用戶提供 JSON 或 CSV 任務文件並要求執行 linyaps 打包
- 用戶要求批量構建多個 linyaps 包
- 用戶提到 `pak_linyaps.sh` 或便捷打包腳本
- 用戶僅提供包名列表（`--pkg-name`、`--task-file` 或管道輸入），需要自動從上游查詢補全 `src_url`/`arch`/`orig_version` 等信息

## JSON 任務文件格式

全局配置支援兩種方式（**雙模式**），按優先級載入：

1. **Inline 模式**（傳統）：任務 JSON 文件中直接包含 `global` 區段（優先級高）
2. **獨立配置文件模式**：使用 `agent-config.json` 提供全局配置（優先級低，inline 無對應字段時回退）

```json
{
  "global": {
    "projects_root": "/path/to/adapted/projects",
    "projects_repo": "git@gitlab.example.com:org/linyaps-packaging-scripts-pool.git",
    "output_dir": "/data/output/${tag}",
    "data_dir": "/data/output/${tag}.log",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  },
  "tasks": [
    {
      "pkgName": "com.opera.browser",
      "src_url": "https://example.com/opera-stable_130.0_amd64.deb",
      "arch": "x86_64",
      "orig_version": "130.0.5847.92"
    }
  ]
}
```

### 欄位說明
| 欄位 | 必填 | 說明 |
|------|------|------|
| `global.projects_root` | 是* | 已適配便捷打包的項目根目錄；若同時設有 `projects_repo` 則以此路徑作為 Git 本地快取目錄 |
| `global.projects_repo` | 否 | 打包腳本 Git 倉庫 URL；設有此值時自動執行 `git clone/pull` 同步，替代本地路徑方案 |
| `global.output_dir` | 否 | 產出目錄，支援 `${tag}` 佔位符（**必須在步驟 1 解析為完整路徑**），預設 `./output` |
| `global.data_dir` | 否 | 數據記錄目錄，支援 `${tag}` 佔位符（**必須在步驟 1 解析為完整路徑**），用於存放 Build Log CSV 等持久化文件 |
| `global.build_tmp_dir` | 否 | 構建緩存**根**目錄，每個 task 自動建立 `<pkgName>/` 子目錄；預設自動生成臨時目錄 |
| `global.src_dir` | 否 | 原始資源下載目錄，預設 `./src` |
| `tasks[].pkgName` | 是 | 包名，用於定位項目子目錄；若僅提供此欄位而無 `src_url`/`arch`/`orig_version`，可配合 `<SKILL_ROOT>/scripts/query_upstream.sh` 自動查詢補全 |
| `tasks[].src_url` | 是 | 原始資源下載地址 |
| `tasks[].arch` | 是 | 目標架構 (x86_64/arm64) |
| `tasks[].orig_version` | 否 | 原始版本號，可從 src_url 自動提取 |

> **`*` 必填說明**：`projects_root` 在無 `projects_repo` 時為必填。若設有 `projects_repo`，則 `projects_root` 可為空，將由 Git 倉庫決定本地路徑（推導為 `projects_root=./projects`）。

> **`${tag}` 路徑即時解析規則（必須遵守）**
> 配置中的路徑可能包含 `${tag}` 佔位符（例如 `/data/output/${tag}`）。
> **你必須在步驟 1 載入配置後立即執行：**
> 1. 運行 `date +"%Y-%m-%d"` 獲取當天日期（如 `2026-06-10`）
> 2. 將所有含有 `${tag}` 的路徑替換為完整路徑（例如 `/data/output/${tag}` → `/data/output/2026-06-10`）
> 3. **將解析後的完整路徑記錄下來**，後續所有步驟（2-9）均使用已解析的完整路徑
> 4. **禁止**將 `${tag}` 原樣傳遞給 bash 命令、mkdir、curl 或其他工具——shell 會將其解析為空值

### 雙模式配置載入邏輯

```
載入順序:
1. 任務文件中的 inline global 優先
2. inline global 中缺失的字段 → 查找 `agent-config.json` 中的同名 global 字段
3. 若 `projects_root` 為空且設有 `projects_repo` → 設定 `projects_root=./projects`，使用 Git 方案克隆/同步倉庫
4. 若上述均無 → 使用對應字段的預設值
```

## agent-config.json 獨立配置

當需要將全局配置與任務列表分離管理時，可使用 `agent-config.json` 文件（存放於工作目錄根目錄）。

**結構**：
```json
{
  "global": {
    "projects_root": "<本地項目目錄>",
    "projects_repo": "<Git 倉庫 URL>",
    "output_dir": "<產出目錄，支援 ${tag} 佔位符>",
    "data_dir": "<數據記錄目錄，支援 ${tag} 佔位符>",
    "build_tmp_dir": "<構建緩存目錄>",
    "src_dir": "<資源下載目錄>"
  },
  "version_extract_examples": [
    {
      "description": "Firefox tar.xz release",
      "url_pattern": "firefox-{version}.en-US.linux-{arch}.tar.xz",
      "extract_regex": "firefox-([0-9]+\\.[0-9]+(?:\\.[0-9]+)*)\\.en-US"
    }
  ]
}
```

### 區段說明

| 區段 | 說明 |
|------|------|
| `global` | 全局配置，與 inline global 字段相同，作為其回退值 |
| `version_extract_examples` | 版本提取規則列表，用於從 URL 中提取版本號 |

## 版本提取規則 (version_extract_examples)

`version_extract_examples` 提供從 `src_url` 中提取 `orig_version` 的規則樣本。當任務的 `orig_version` 為空時，按以下順序嘗試提取：

1. **規則匹配**：遍歷 `version_extract_examples` 中的正則表達式，與 URL 進行匹配
2. **通用匹配**：若上述規則無匹配，使用通用模式 `x.y.z`（或 `x.y`）提取版本號
3. **提取失敗**：若無法提取，記錄警告，後續步驟由 LLM 分析判斷

## CSV 任務文件格式

除了 JSON 格式，也支持 CSV 格式導入任務。使用 `csv_to_json.sh` 腳本（位於 `<SKILL_ROOT>/scripts/`）進行轉換和執行。

### CSV 表頭

```csv
记录ID,包名,架构,版本,网站地址,下载地址
```

### 欄位映射

| CSV 欄位 | JSON 欄位 | 必填 | 說明 |
|----------|-----------|------|------|
| `记录ID` | (忽略) | 否 | 僅供參考 |
| `包名` | `pkgName` | 是 | 包名，用於定位項目子目錄 |
| `架构` | `arch` | 是 | 目標架構 (x86_64/arm64) |
| `版本` | `orig_version` | 否 | 原始版本號，為空時從 URL 自動提取 |
| `网站地址` | (忽略) | 否 | 僅供參考 |
| `下载地址` | `src_url` | 是 | 原始資源下載地址 |

### 使用方式

```bash
# 基本用法：CSV 導入 + 預設配置
bash <SKILL_ROOT>/scripts/csv_to_json.sh tasks.csv --projects_root=/path/to/projects

# 僅生成 JSON 不執行 (dry-run)
bash <SKILL_ROOT>/scripts/csv_to_json.sh tasks.csv --dry-run

# 使用 JSON 配置文件提供 global 設定
bash <SKILL_ROOT>/scripts/csv_to_json.sh tasks.csv --config=global_config.json

# 完整參數
bash <SKILL_ROOT>/scripts/csv_to_json.sh tasks.csv \
  --projects_root=/path/to/projects \
  --output_dir=./output \
  --src_dir=./src

# 向後兼容：直接使用 JSON 任務文件
bash <SKILL_ROOT>/scripts/csv_to_json.sh task.json
```

### 命令行參數

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `--projects_root=<path>` | `./projects` | 項目根目錄 |
| `--output_dir=<path>` | `./output` | 輸出目錄 |
| `--build_tmp_dir=<path>` | (自動生成) | 構建緩存根目錄，每個 task 自動建立 `<pkgName>/` 子目錄 |
| `--src_dir=<path>` | `./src` | 原始資源下載目錄 |
| `--config=<file.json>` | (無) | JSON 配置文件 (僅含 global 部分) |
| `--output=<file.json>` | (自動生成) | 輸出 JSON 文件路徑 |
| `--dry-run` | false | 僅生成 JSON，不執行打包 |

### 數據清理

腳本會自動處理以下數據質量問題：
- 移除欄位前後的空白字符和 tab 字符
- 支持簡體/繁體中文表頭
- 跳過缺少必要欄位（包名、下载地址、架构）的行

## 上游信息查詢 (query_upstream.sh)

當上游平台下發的任務僅包含包名（`pkgName`）而缺少 `src_url`、`arch`、`orig_version` 等關鍵信息時，使用此腳本從上游 API 自動查詢補全。

### 腳本位置

位於 `<SKILL_ROOT>/scripts/query_upstream.sh`。

### API 字段映射

腳本調用上游 API 後，將返回字段映射為標準任務格式：

| API 返回字段 | 映射到任務字段 | 說明 |
|-------------|---------------|------|
| `appid` | `pkgName` | 包名 |
| `download_url` | `src_url` | 原始資源下載地址 |
| `version` | `orig_version` | 原始版本號 |
| `arch` | `arch` | 目標架構 (x86_64/arm64) |

### 輸入方式

腳本支援三種輸入方式：

```bash
# 方式 1: 直接指定包名（支援逗號分隔多個包名）
bash <SKILL_ROOT>/scripts/query_upstream.sh --pkg-name=net.kuribo64.melonDS
bash <SKILL_ROOT>/scripts/query_upstream.sh --pkg-name=com.opera.browser,com.google.chrome

# 方式 2: 從文件讀取（支援 JSON 或純文本格式）
bash <SKILL_ROOT>/scripts/query_upstream.sh --task-file=task.json
bash <SKILL_ROOT>/scripts/query_upstream.sh --task-file=pkglist.txt

# 方式 3: 管道輸入（每行一個包名）
echo "net.kuribo64.melonDS" | bash <SKILL_ROOT>/scripts/query_upstream.sh
```

### 合併 Global 配置

可透過 `--global-config` 傳入 `agent-config.json`，合併輸出完整的任務 JSON：

```bash
bash <SKILL_ROOT>/scripts/query_upstream.sh \
  --pkg-name=net.kuribo64.melonDS \
  --global-config=for-multica/agent-config.json \
  --output=full-tasks.json
```

### 輸出格式

輸出爲標準任務 JSON，與 `run_tasks.sh` 完全相容：

```json
{
  "global": {
    "projects_root": "...",
    "output_dir": "...",
    "build_tmp_dir": "...",
    "src_dir": "./src"
  },
  "tasks": [
    {
      "pkgName": "net.kuribo64.melonDS",
      "src_url": "https://...",
      "arch": "x86_64",
      "orig_version": "1.1"
    }
  ]
}
```

### 注意事項

- 依賴 `python3` 和 `curl`，執行前會自動檢查
- 若輸入的 JSON 任務文件已包含完整的 `src_url`/`arch`/`orig_version`，腳本會直接透傳，**不會**重複查詢 API
- API 不可達或返回錯誤時，腳本會記錄錯誤信息並繼續處理其他包名（不阻斷批量流程）
- 支持透過 `--api-url=<url>` 覆蓋默認 API 地址
- **禁止**使用 `fetch_webpage` 或瀏覽器工具自行爬取上游網站獲取版本/下載地址——上游信息必須通過 `<SKILL_ROOT>/scripts/query_upstream.sh` 調用 API 或任務 JSON 中已有的字段獲取

## 執行流程

### 步驟 1: 載入配置與解析任務文件

1. **載入全局配置**（雙模式）：
   - 優先使用任務文件中的 inline `global` 區段
   - inline 中缺失的字段 → 查找 `./agent-config.json` 中的同名 `global` 字段
   - 若 `projects_root` 為空且設有 `projects_repo` → 設定 `projects_root=./projects`，啟用 Git 方案
   - 若上述均無 → 使用對應字段的預設值
2. **`${tag}` 變量解析與路徑固化**：嚴格遵守上面「`${tag}` 路徑即時解析規則」：
   - 運行 `date +"%Y-%m-%d"` 獲取實際日期
   - 將所有含 `${tag}` 的 global 路徑變量替換為完整路徑
   - **記錄最終路徑為此步驟的輸出**，後續步驟（2-9）不再回退到原始值
3. **解析 `version_extract_examples`**：若 `agent-config.json` 中存在，載入版本提取規則列表
4. **解析任務文件**（用戶提供的 JSON 或 CSV）：
   - JSON 格式直接解析提取 `tasks` 列表
   - CSV 格式先用 `<SKILL_ROOT>/scripts/csv_to_json.sh` 轉換為 JSON 再執行

### 步驟 2: 初始化目錄與同步打包腳本倉庫

- **同步 `./projects/` 目錄**（打包腳本倉庫快取，僅當設有 `projects_repo` 時執行）：
  - 若目錄已存在 → `cd ./projects/ && git pull`，確保腳本為最新版本
  - 若目錄不存在 → `git clone <projects_repo> ./projects/`
  - 若 `git pull` 因網絡等原因失敗 → 保留現有快取版本繼續執行，**不阻斷流程**
- 建立 `src_dir`（原始資源目錄）
- 建立 `output_dir`（輸出目錄）
- 若 `build_tmp_dir` 為空，自動生成臨時目錄作為緩存根目錄
- 建立 `data_dir`（數據記錄目錄）

> **時效性說明**：每次任務觸發時都執行 `git pull`，確保打包腳本倉庫始終與遠程保持同步。若遠程倉庫無新提交，`git pull` 僅做 fast-forward 檢查，幾乎無開銷。

### 步驟 3: 下載原始資源

對每個任務：
1. 若 `orig_version` 為空，從 `src_url` 中提取版本號（優先使用 `version_extract_examples` 中的正則，否則通用匹配 `x.y.z` 模式）
2. 使用 `curl -L --speed-limit 1024 --speed-time 10` 下載資源到 `src_dir`
3. 使用 `file` 命令檢查下載文件格式是否正常
4. 注意處理重定向 URL（如 VS Code 的 `/latest/` 類型 URL，需先解析 `Location` 頭獲取實際地址）

### 步驟 4: 架構驗證

使用 `arch_mapping.json` 映射表比對 `src_url` 中的架構特徵與 `tasks[].arch`：

1. **Token 匹配**：掃描 URL 中出現的已知架構關鍵字（`amd64` → `x86_64`、`arm64` → `arm64`、`i386` → 不支援等）
2. **Regex 匹配**：針對特定 URL 模式（如 `linux-deb-x64`、`_amd64.deb$`、`linux-x86_64` 等）
3. **比對結果**：
   - **MATCH** → 通過，繼續執行
   - **MISMATCH** → 報錯跳過該任務，計入失敗統計
   - **UNKNOWN** → 映射表無法識別 URL 中的架構特徵，由 LLM 分析判斷（不阻斷流程）

### 步驟 5: 定位項目

在 `./projects/`（或 `projects_root`）下查找 `pkgName` 對應的項目目錄：

1. 優先嘗試 `CI_ll_<pkgName>` 格式
2. 其次直接匹配 `<pkgName>`
3. 最後模糊搜索包含 `pkgName` 的目錄
4. 若上述查找均未找到對應項目目錄：
   - **暫停該任務**的後續處理（不下載、不打包）
   - 記錄失敗原因為「項目未適配」
   - 該任務計入「待初始化」狀態，不計入成功或失敗統計
   - **繼續處理下一個任務**（不阻斷整個流程）
5. 找到項目後，確認目標目錄下存在 `pak_linyaps.sh`

### 步驟 5.5: 前置項目驗證（檢測閘門）

**必須在步驟 5 之後、步驟 6 之前執行此驗證。**

根據任務的輸入類型選擇對應的呼叫方式：

**場景 A：已有 JSON 任務文件**（來自步驟 1 解析的 JSON/CSV，或 `query_upstream.sh` 的輸出）
```bash
bash <SKILL_ROOT>/scripts/validate_projects.sh \
  --task-file=<task.json路徑> \
  --projects-root=<projects_root解析後路徑> \
  --output=<data_dir>/validate_result.json
```

**場景 B：自然語言輸入或僅有包名列表**（如用戶直接說「打包 opera 和 vscode」，或通過 `--pkg-name` 指定）
```bash
bash <SKILL_ROOT>/scripts/validate_projects.sh \
  --pkg-name=<逗號分隔的包名列表> \
  --projects-root=<projects_root解析後路徑> \
  --output=<data_dir>/validate_result.json
```

1. **執行檢測腳本**：根據輸入場景選擇上述對應命令，對所有包名進行項目完整度校驗
2. **分支處理**：
   - 退出碼 0（全部通過）→ 繼續執行步驟 6
   - 退出碼 1（存在失敗）→ **立即終止打包流程**，輸出檢測結果表格，跳至步驟 8 輸出統計結論。**不得**繞過檢測結果自行繼續打包
3. **驗證不通過的任務**已被檢測腳本標記為 NOT_FOUND 或 FAIL，這些任務**不得**進入步驟 6-7 的生成命令和打包流程
4. 檢測腳本的 JSON 結果文件寫入 `data_dir/validate_result.json`，可作為後續審查存證

### 步驟 6: 生成打包命令

為每個任務生成命令：
```bash
cd <project_dir>
./pak_linyaps.sh \
  --linyaps_arch=<arch> \
  --origin_version=<orig_version> \
  --src_path="<src_path>" \
  --output_dir="<output_dir>" \
  [--build_tmp_dir=<build_tmp_dir>/<pkgName>]
```

注意：
- 每個任務使用獨立的 `build_tmp_dir/<pkgName>/` 子緩存目錄
- `--build_tmp_dir` 參數**必須先檢測** `pak_linyaps.sh` 中是否包含 `build_tmp_dir` 關鍵字，非所有項目都支援

### 步驟 7: 執行打包

- 在項目目錄下執行生成的命令
- 後台執行，輸出重定向到 `output_dir/<pkgName>.log`
- 捕獲最後數行輸出作為結果參考
- 記錄耗時、成功/失敗狀態

### 步驟 7.5: 任務狀態持久化（Build Log CSV）

路徑：`<data_dir已解析值>/<tag>.buildLog.csv`
   - `data_dir` 為步驟 1 中已解析 `${tag}` 後的完整路徑（例如 `/data/linyaps-CI-output/2026-06-10.log`）
   - 在 bash 命令中直接使用完整路徑：`echo "pkgName^version^url^success" >> /data/linyaps-CI-output/2026-06-10.log/2026-06-10.buildLog.csv`

每個任務完成後，將結果持久化寫入 build log CSV：

1. **CSV 格式**：
   - 分隔符：`^`（避免 URL 中的逗號或空格乾擾）
   - 表頭：`pkgName^orig_version^src_url^build_status`
   - 狀態值：僅 `success` / `failed`（待初始化任務不寫入 CSV）

2. **寫入規則**：
   - CSV 文件不存在 → 先寫入表頭行，再寫入數據行
   - CSV 文件已存在 → 僅追加數據行（不重複寫入表頭）
   - 使用 shell 追加重定向 `>>` 實現，每次寫入為原子操作

3. **成功** → 寫入一行：`<pkgName>^<orig_version>^<src_url>^success`
4. **失敗（打包執行錯誤）** → 寫入一行：`<pkgName>^<orig_version>^<src_url>^failed`
5. **待初始化（找不到項目）** → 不寫入 CSV（該類任務已在步驟 5 記錄指派狀態，僅計入內存統計）

### 步驟 8: 輸出結果統計

彙總輸出（統計數據可從 build log CSV 讀取作為持久化依據）：
- 總任務數
- 成功數 / 失敗數 / 待初始化數
- 每個任務的結果（成功耗時 / 失敗錯誤信息 / 待初始化指派狀態）

### 步驟 9: 最終狀態更新

1. **彙總所有任務結果**（成功數 / 失敗數 / 待初始化數）
2. **更新狀態**：
   - 全部成功 → "審查完成"
   - 部分失敗或存在待初始化任務 → "部分完成"
   - 全部失敗（無待初始化任務） → "阻塞"
3. **輸出存證**：將 build log CSV 路徑記錄到輸出摘要中

## 結果處理

- **成功**：記錄成功數量和每個任務的耗時
- **失敗**：記錄失敗原因（下載失敗、架構不匹配、打包腳本執行錯誤等），輸出對應日誌文件路徑
- **待初始化**：記錄已暫停的待初始化任務清單（項目未適配）
- 所有任務完成後輸出統計摘要

## 約束

- **打包入口唯一性**：所有打包操作**必須**通過項目目錄下的 `pak_linyaps.sh` 腳本執行，這是唯一合法的打包入口。**嚴禁**自行生成/改寫 `linglong.yaml` 或直接調用 `ll-builder`、`ll-pica` 等工具進行打包。若項目目錄下不存在 `pak_linyaps.sh`，應視為「項目未適配」並按步驟 5 的待初始化流程處理，而非自行手動打包。步驟 5.5 的前置項目驗證腳本 `<SKILL_ROOT>/scripts/validate_projects.sh` 是檢測閘門——驗證不通過的任務不得繼續打包
- 執行前確保 `pak_linyaps.sh` 有執行權限（`chmod +x`）
- `--build_tmp_dir` 參數必須先檢測腳本是否支援再決定是否加入命令
- 如果多架構的版本不一致，優先使用 x86_64 架構的版本
- 下載資源時注意 `--speed-limit` 和 `--speed-time` 參數避免網絡卡死
- 資源文件已存在時跳過下載（避免重複）
- 不要修改 `pak_linyaps.sh` 或 `linglong.yaml` 的內容，直接使用現有腳本
- 除了必要的目錄初始化，不要讀寫工作目錄之外的任何文件
- Git 快取目錄 `./projects/` 跨任務保留，**每次任務自動 `git pull`** 增量更新，不重複克隆
- `global.build_tmp_dir` 是緩存**根**目錄，每個 task 會自動建立 `<pkgName>/` 子目錄（如 `./build_cache/com.opera.browser/`），避免任務間緩存衝突
- 下載資源時注意處理重定向 URL（如 VS Code 的 `/latest/` 類型 URL，需先解析 `Location` 頭獲取實際地址）
