English | **[中文](README.zh-CN.md)**

# linyaps Packaging Runner

Automated task orchestration for [linyaps](https://www.linyaps.org.cn/) (琥珀) packaging scripts. This tool reads task definitions from **JSON** or **CSV** files, downloads upstream sources, locates pre-adapted packaging projects, and executes `pak_linyaps.sh` build commands in batch.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Task File Formats](#task-file-formats)
  - [JSON Format](#json-format)
  - [CSV Format](#csv-format)
- [Command-Line Reference](#command-line-reference)
  - [csv_to_json.sh](#csv_to_jsonsh)
  - [run_tasks.sh](#run_taskssh)
- [Execution Flow](#execution-flow)
- [Architecture Validation](#architecture-validation)
- [Demo Files](#demo-files)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)

---

## Prerequisites

| Dependency | Purpose |
|------------|---------|
| `bash` ≥ 4.0 | Script execution |
| `python3` | JSON parsing, CSV conversion, architecture validation |
| `curl` | Downloading upstream source packages |
| `jq` (optional) | Human-readable JSON inspection |

## Project Structure

```
.
├── SKILL.md                  # Skill definition for AI agent integration
├── README.md                 # This file (English)
├── README.zh-CN.md           # Chinese version
├── task-example.json         # Example JSON task file
├── arch_mapping.json         # Architecture keyword → linyaps arch mapping
├── scripts/
│   ├── csv_to_json.sh        # CSV-to-JSON converter & unified entry point
│   └── run_tasks.sh          # Core task executor (JSON-based)
└── demo-files/
    ├── taskInfo.example.csv               # Example CSV (2 tasks)
    ├── Upstream_20260528133849.csv        # Real-world CSV (9 tasks)
    ├── CI_ll_com.opera.browser/           # Demo: Opera packaging project
    │   ├── pak_linyaps.sh
    │   ├── scripts/
    │   └── templates/
    └── CI_ll_com.visualstudio.code/       # Demo: VS Code packaging project
        ├── pak_linyaps.sh
        ├── src/
        └── templates/
```

### Key Files Explained

| File | Description |
|------|-------------|
| `scripts/csv_to_json.sh` | **Unified entry point** — accepts both CSV and JSON task files. Converts CSV to JSON, then delegates to `run_tasks.sh`. |
| `scripts/run_tasks.sh` | Core executor — parses JSON tasks, downloads sources, validates architectures, and runs `pak_linyaps.sh` for each task. |
| `arch_mapping.json` | Maps URL architecture keywords (e.g., `amd64`, `x64`, `aarch64`) to linyaps architecture identifiers (`x86_64`, `arm64`). |
| `task-example.json` | Reference JSON task file with `version_extract_examples` for automatic version extraction. |

---

## Quick Start

### Using a CSV file

```bash
# 1. Prepare a CSV file with headers: 记录ID,包名,架构,版本,网站地址,下载地址

# 2. Preview the generated JSON (dry-run mode)
./scripts/csv_to_json.sh demo-files/taskInfo.example.csv --dry-run

# 3. Execute packaging with your adapted projects
./scripts/csv_to_json.sh demo-files/taskInfo.example.csv \
  --projects_root=/path/to/adapted/projects
```

### Using a JSON file

```bash
# Direct execution with a JSON task file
./scripts/run_tasks.sh task-example.json
```

---

## Task File Formats

### JSON Format

A JSON task file contains a `global` configuration block and a `tasks` array:

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

#### Field Descriptions

**Global Configuration:**

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `projects_root` | **Yes** | — | Root directory containing adapted packaging projects |
| `output_dir` | No | `./output` | Directory for build outputs |
| `build_tmp_dir` | No | *(auto-generated)* | Build cache directory; if empty, a temp directory is created |
| `src_dir` | No | `./src` | Directory for downloaded source packages |

**Task Entry:**

| Field | Required | Description |
|-------|----------|-------------|
| `pkgName` | **Yes** | Package name, used to locate the matching project directory (e.g., `com.opera.browser`) |
| `src_url` | **Yes** | Upstream source download URL |
| `arch` | **Yes** | Target architecture: `x86_64` or `arm64` |
| `orig_version` | No | Upstream version string; if empty, auto-extracted from `src_url` |

**Optional: Version Extraction Patterns** (top-level `version_extract_examples`):

When `orig_version` is empty, the script tries to match the `src_url` against these patterns to extract the version number automatically. See `task-example.json` for examples.

---

### CSV Format

CSV files must use UTF-8 encoding with the following header row:

```csv
记录ID,包名,架构,版本,网站地址,下载地址
```

#### Field Mapping

| CSV Column | JSON Field | Required | Description |
|------------|------------|----------|-------------|
| `记录ID` | *(ignored)* | No | Reference ID, not used |
| `包名` | `pkgName` | **Yes** | Package name for project directory lookup |
| `架构` | `arch` | **Yes** | Target architecture (`x86_64` / `arm64`) |
| `版本` | `orig_version` | No | Upstream version; if empty, auto-extracted from URL |
| `网站地址` | *(ignored)* | No | Project homepage, not used |
| `下载地址` | `src_url` | **Yes** | Upstream source download URL |

#### Example CSV

```csv
记录ID,包名,架构,版本,网站地址,下载地址
1cea051c-...,com.jetbrains.www.pycharm,x86_64,2026.1.2,https://data.services.jetbrains.com/...,https://rustfsadmin.../com.jetbrains.www.pycharm_x86_64_2026.1.2.tar.gz
c7c2946f-...,org.mozilla.firefox-nal,x86_64,151.0.2,https://www.firefox.com/zh-CN/,https://rustfsadmin.../org.mozilla.firefox-nal_x86_64_151.0.2.tar.xz
```

#### Data Cleaning

The converter automatically handles:
- **Whitespace trimming**: Leading/trailing spaces and tabs are removed from all fields
- **Header aliases**: Both simplified (下载地址) and traditional (下載地址) Chinese headers are accepted
- **Row skipping**: Rows missing required fields (`包名`, `下载地址`, `架构`) are silently skipped

#### Global Configuration for CSV

Since CSV files have no `global` section, configuration is provided via:

1. **Command-line arguments** (highest priority):
   ```bash
   ./scripts/csv_to_json.sh tasks.csv \
     --projects_root=/path/to/projects \
     --output_dir=./output \
     --src_dir=./src
   ```

2. **JSON config file** (`--config`):
   ```bash
   ./scripts/csv_to_json.sh tasks.csv --config=global_config.json
   ```
   Where `global_config.json` contains only the `global` section:
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

3. **Default values** (lowest priority):
   | Parameter | Default |
   |-----------|---------|
   | `projects_root` | `./projects` |
   | `output_dir` | `./output` |
   | `build_tmp_dir` | *(auto-generated temp dir)* |
   | `src_dir` | `./src` |

---

## Command-Line Reference

### csv_to_json.sh

**Unified entry point** — accepts both CSV and JSON files.

```
./scripts/csv_to_json.sh <task.csv|task.json> [options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--projects_root=<path>` | `./projects` | Root directory of adapted packaging projects |
| `--output_dir=<path>` | `./output` | Output directory for build artifacts |
| `--build_tmp_dir=<path>` | *(auto)* | Build cache directory |
| `--src_dir=<path>` | `./src` | Directory for downloaded source packages |
| `--config=<file.json>` | *(none)* | JSON config file providing `global` settings |
| `--output=<file.json>` | *(auto)* | Output path for the generated JSON task file |
| `--dry-run` | `false` | Generate JSON only; do not execute packaging |
| `--help` | — | Show usage information |

**Behavior by file type:**
- **CSV input** → Converts to JSON → Executes via `run_tasks.sh`
- **JSON input** → Passes directly to `run_tasks.sh` (backward compatible)

### run_tasks.sh

**Core executor** — processes JSON task files directly.

```
./scripts/run_tasks.sh <task.json>
```

This script is called internally by `csv_to_json.sh` but can also be used standalone with a JSON task file.

---

## Execution Flow

```
┌─────────────────────────────────────────────────────────────┐
│  1. Parse Task File                                         │
│     CSV → csv_to_json.sh → JSON                             │
│     JSON → direct use                                        │
├─────────────────────────────────────────────────────────────┤
│  2. Initialize Directories                                  │
│     Create: src_dir, output_dir, build_tmp_dir              │
├─────────────────────────────────────────────────────────────┤
│  3. For Each Task:                                          │
│     ┌───────────────────────────────────────────────────┐   │
│     │ 3a. Extract version from URL (if not provided)    │   │
│     │ 3b. Validate architecture (URL vs declared arch)  │   │
│     │ 3c. Download source package to src_dir            │   │
│     │ 3d. Locate project directory in projects_root     │   │
│     │     (matches CI_ll_<pkgName> or <pkgName>)        │   │
│     │ 3e. Detect --build_tmp_dir support                │   │
│     │ 3f. Execute pak_linyaps.sh with generated args    │   │
│     └───────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│  4. Output Summary                                          │
│     Total / Success / Fail counts + per-task details        │
└─────────────────────────────────────────────────────────────┘
```

Each task produces a log file at `<output_dir>/<pkgName>.log`.

---

## Architecture Validation

Before downloading, the script validates that the architecture declared in the task matches the architecture implied by the download URL.

### How It Works

1. **Token matching**: Scans the URL for known architecture keywords from `arch_mapping.json`
   - `amd64`, `x64`, `x86_64`, `intel` → `x86_64`
   - `arm64`, `aarch64`, `armv8` → `arm64`
   - `i386`, `i686`, `armhf`, `armv7` → unsupported (triggers mismatch)

2. **Regex matching**: Applies URL-pattern-specific rules
   - `linux-deb-x64/stable` → `x86_64` (VS Code style)
   - `_amd64.deb` → `x86_64` (Debian package suffix)

3. **Result handling**:

   | Result | Behavior |
   |--------|----------|
   | **MATCH** | ✅ Proceed with packaging |
   | **MISMATCH** | ❌ Skip task, count as failure |
   | **UNKNOWN** | ⚠️ Print LLM analysis prompt, continue execution |

### Example

```
[OK] 架構驗證通過: URL 含架構(x86_64) → 宣告 arch(x86_64) ✓
[ERROR] 架構不匹配: URL 含架構(x86_64)，但宣告 arch 為 arm64
```

---

## Demo Files

The `demo-files/` directory contains ready-to-use examples:

### taskInfo.example.csv

A minimal CSV with 2 tasks:
- `com.jetbrains.www.pycharm` — PyCharm (x86_64)
- `org.mozilla.firefox-nal` — Firefox (x86_64)

### Upstream_20260528133849.csv

A real-world CSV with 9 tasks covering browsers, media players, and development tools.

### CI_ll_com.opera.browser

A fully adapted Opera packaging project demonstrating the expected project structure:
```
CI_ll_com.opera.browser/
├── pak_linyaps.sh          # Main packaging script
├── scripts/                # Helper scripts
│   ├── dedup_desktop_files.sh
│   ├── handle_special_paths.sh
│   └── validate_bin_nesting.sh
└── templates/
    ├── linglong.yaml       # linyaps manifest template
    └── files_res/          # Desktop files, icons, etc.
```

### CI_ll_com.visualstudio.code

A fully adapted VS Code packaging project with similar structure, including `appdata.xml`, `bash-completion`, and `zsh` completions.

---

## Troubleshooting

### "找不到項目目錄" (Project directory not found)

The script looks for project directories under `projects_root` in this order:
1. `CI_ll_<pkgName>/pak_linyaps.sh`
2. `<pkgName>/pak_linyaps.sh`
3. Fuzzy match: any directory containing `<pkgName>` with a `pak_linyaps.sh`

**Solution**: Ensure your adapted projects are in `projects_root` and follow the `CI_ll_<pkgName>` naming convention.

### "架構不匹配" (Architecture mismatch)

The URL contains architecture keywords that contradict the declared `arch` field.

**Solution**: Verify the `arch` field in your task file matches the actual package architecture. Check `arch_mapping.json` for supported mappings.

### "無法從 URL 提取版本號" (Cannot extract version from URL)

The `orig_version` field is empty and the URL doesn't match any known version pattern.

**Solution**: Explicitly set `orig_version` in your task file, or add a new pattern to `version_extract_examples` in your JSON task file.

### "CSV 缺少必要欄位" (CSV missing required columns)

The CSV file is missing one or more of: `包名`, `下载地址`, `架构`.

**Solution**: Ensure your CSV file includes the header row with all required columns.

### Download fails for redirect URLs

Some URLs (e.g., VS Code's `update.code.visualstudio.com/latest/...`) require redirect following.

**Solution**: The script automatically handles redirects via `curl -L`. If issues persist, pre-download the file and use a direct URL.

---

## Notes

- **`--build_tmp_dir` support is not universal**: The script auto-detects whether a project's `pak_linyaps.sh` supports this parameter by searching for the `build_tmp_dir` keyword. If unsupported, the parameter is silently omitted.
- **Execution permissions**: Ensure `pak_linyaps.sh` scripts have execute permission (`chmod +x`).
- **UTF-8 encoding**: CSV files must be UTF-8 encoded. Both simplified and traditional Chinese headers are supported.
- **Concurrent execution**: Tasks run sequentially. For parallel execution, split your task file and run multiple instances with separate `output_dir` and `build_tmp_dir` values.
- **Backward compatibility**: `csv_to_json.sh` transparently handles JSON files by passing them directly to `run_tasks.sh`, so you can use it as a single entry point for both formats.
