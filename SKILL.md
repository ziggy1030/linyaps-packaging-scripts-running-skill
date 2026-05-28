---
name: linyaps-packaging-runner
description: '自動執行 linyaps 琥珀打包腳本。當用戶提供 JSON 或 CSV 任務文件並要求執行 linyaps 打包時使用。關鍵詞: pak_linyaps, linyaps, 琥珀, 打包, linglong, build, package, csv, json。'
argument-hint: '<task.json|task.csv>'
user-invocable: true
---

# linyaps 便捷打包腳本自動執行

## 用途
根據用戶提供的 JSON 任務文件，自動下載原始資源、定位已適配便捷打包的項目、生成並執行 `pak_linyaps.sh` 打包命令。

## 何時使用
- 用戶提供 JSON 或 CSV 任務文件並要求執行 linyaps 打包
- 用戶要求批量構建多個 linyaps 包
- 用戶提到 `pak_linyaps.sh` 或便捷打包腳本

## JSON 任務文件格式

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
| `global.projects_root` | 是 | 已適配便捷打包的項目根目錄 |
| `global.output_dir` | 否 | 輸出目錄，預設 `./output` |
| `global.build_tmp_dir` | 否 | 構建緩存目錄，預設自動生成臨時目錄 |
| `global.src_dir` | 否 | 原始資源下載目錄，預設 `./src` |
| `tasks[].pkgName` | 是 | 包名，用於定位項目子目錄 |
| `tasks[].src_url` | 是 | 原始資源下載地址 |
| `tasks[].arch` | 是 | 目標架構 (x86_64/arm64) |
| `tasks[].orig_version` | 否 | 原始版本號，可從 src_url 自動提取 |

## CSV 任務文件格式

除了 JSON 格式，也支持 CSV 格式導入任務。使用 `scripts/csv_to_json.sh` 腳本進行轉換和執行。

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
./scripts/csv_to_json.sh tasks.csv --projects_root=/path/to/projects

# 僅生成 JSON 不執行 (dry-run)
./scripts/csv_to_json.sh tasks.csv --dry-run

# 使用 JSON 配置文件提供 global 設定
./scripts/csv_to_json.sh tasks.csv --config=global_config.json

# 完整參數
./scripts/csv_to_json.sh tasks.csv \
  --projects_root=/path/to/projects \
  --output_dir=./output \
  --src_dir=./src

# 向後兼容：直接使用 JSON 任務文件
./scripts/csv_to_json.sh task.json
```

### 命令行參數

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `--projects_root=<path>` | `./projects` | 項目根目錄 |
| `--output_dir=<path>` | `./output` | 輸出目錄 |
| `--build_tmp_dir=<path>` | (自動生成) | 構建緩存目錄 |
| `--src_dir=<path>` | `./src` | 原始資源下載目錄 |
| `--config=<file.json>` | (無) | JSON 配置文件 (僅含 global 部分) |
| `--output=<file.json>` | (自動生成) | 輸出 JSON 文件路徑 |
| `--dry-run` | false | 僅生成 JSON，不執行打包 |

### 數據清理

腳本會自動處理以下數據質量問題：
- 移除欄位前後的空白字符和 tab 字符
- 支持簡體/繁體中文表頭
- 跳過缺少必要欄位（包名、下载地址、架构）的行

## 執行流程

### 步驟 1: 解析任務文件
讀取用戶提供的任務文件（JSON 或 CSV 格式）：
- **JSON 格式**：直接由 `run_tasks.sh` 解析，提取 `global` 配置和 `tasks` 列表
- **CSV 格式**：由 `csv_to_json.sh` 轉換為 JSON 後再執行

### 步驟 2: 初始化目錄
- 建立 `src_dir`（原始資源目錄）
- 建立 `output_dir`（輸出目錄）
- 若 `build_tmp_dir` 為空，自動生成臨時目錄

### 步驟 3: 下載原始資源
對每個任務：
1. 若 `orig_version` 為空，從 `src_url` 中提取版本號
2. 下載原始資源到 `src_dir`，記錄本地路徑

### 步驟 4: 定位項目並生成命令
對每個任務：
1. 在 `projects_root` 下查找 `pkgName` 對應的項目目錄（匹配 `CI_ll_<pkgName>` 或直接匹配 `pkgName`）
2. 確認項目目錄下存在 `pak_linyaps.sh`
3. **檢測 `--build_tmp_dir` 支援**：在 `pak_linyaps.sh` 中搜尋 `build_tmp_dir` 關鍵字，若存在則在命令中包含該參數
4. 生成打包命令：
```bash
./pak_linyaps.sh \
  --linyaps_arch=<arch> \
  --origin_version=<orig_version> \
  --src_path="<src_path>" \
  --output_dir="<output_dir>" \
  [--build_tmp_dir=<build_tmp_dir>]
```

### 步驟 5: 執行打包
- 在項目目錄下執行生成的命令
- 使用後台執行提高效率，捕獲最後數行輸出
- 記錄每個任務的執行結果（成功/失敗）

### 步驟 6: 輸出結果統計
所有任務完成後，彙總輸出：
- 總任務數
- 成功數 / 失敗數
- 失敗任務的錯誤信息

## 架構驗證

腳本會自動驗證 `tasks[].src_url` 與 `tasks[].arch` 是否匹配：

1. **映射表為主**：使用 `arch_mapping.json` 中的 token 映射表和 regex pattern
   - Token 匹配：掃描 URL 中出現的已知架構關鍵字（如 `amd64`、`arm64`、`x86_64` 等）
   - Regex 匹配：針對特定 URL 模式（如 `linux-deb-x64`、`_amd64.deb$` 等）
   - 已知但不支援的架構（如 `i386`、`armhf`）也會被識別為不匹配
2. **比對結果**：
   - **MATCH** → 通過，繼續執行
   - **MISMATCH** → 報錯並跳過該任務，計入失敗統計
   - **UNKNOWN** → 映射表無法識別 URL 中的架構特徵，輸出 LLM 分析請求（不阻斷流程）
3. **LLM 分析**：當映射表無法識別時，AI 收到包含 `pkgName`、`src_url`、`arch` 的分析請求，協助判斷架構是否正確

## 注意事項
- `--build_tmp_dir` 參數並非所有項目都支援，**必須**先檢測 `pak_linyaps.sh` 中是否包含 `build_tmp_dir` 關鍵字再決定是否加入
- 執行前確認 `pak_linyaps.sh` 有執行權限
- 下載資源時注意處理重定向 URL（如 VS Code 的 update URL）
