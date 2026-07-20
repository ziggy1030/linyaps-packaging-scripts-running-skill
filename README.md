English | **[中文](README.zh-CN.md)**

# linyaps Packaging Runner

Automated task orchestration for [linyaps](https://www.linyaps.org.au/) packaging. Reads task definitions from **JSON** or **CSV** files and dispatches them to the appropriate sub-skill — **binary** tasks use `pak_linyaps.sh` for pre-adapted projects; **source** tasks use `ll-builder build` + `ll-builder export` for source-compiled projects.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Task File Formats](#task-file-formats)
  - [JSON Format](#json-format)
  - [CSV Format](#csv-format)
- [Task Types](#task-types)
  - [Binary (default)](#binary-default)
  - [Source](#source)
- [Command-Line Reference](#command-line-reference)
  - [csv_to_json.sh](#csv_to_jsonsh)
- [Execution Flow](#execution-flow)
- [Architecture Validation](#architecture-validation)
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
| `ll-builder` | Source-compiled tasks only |
| `python3-ruamel.yaml` | Source tasks: linglong.yaml update |
| `python3-yaml` | Source tasks: YAML validation |

## Architecture Overview

```
User Task (JSON/CSV)
    │
    ▼
┌─────────────────────────────────────┐
│  agents/linyaps-packaging-runner    │  ← Agent entry (dispatch logic)
│  ├─ reads agent-config.json         │
│  ├─ groups tasks by type            │
│  └─ dispatches to sub-skill         │
└──────────┬──────────────────────────┘
       type│                    type
    ┌──────┴──────┐      ┌──────┴──────┐
    │ binary      │      │ source      │
    │ (or unset)  │      │             │
    ▼             ▼      ▼             ▼
┌──────────────────┐ ┌──────────────────────┐
│ linglong-binary- │ │ linglong-source-     │
│ runner           │ │ updater              │
│                  │ │                      │
│ pak_linyaps.sh   │ │ ll-builder build     │
│                  │ │ ll-builder export    │
└──────────────────┘ └──────────────────────┘
```

## Project Structure

```
.
├── agents/
│   └── linyaps-packaging-runner.agent.md   # Agent entry point
├── agent-config.json                       # Global configuration
├── scripts/
│   ├── common.sh                           # Shared library (14 functions)
│   ├── csv_to_json.sh                      # CSV-to-JSON converter & unified entry
│   ├── query_upstream.sh                   # Upstream info lookup
│   ├── status_upload.sh                    # Artifact upload
│   └── check-agent-status.sh               # Agent health check
├── skills/
│   ├── config/
│   │   └── arch_mapping.json               # URL arch keyword → linyaps arch
│   ├── linglong-binary-runner/             # Binary packaging sub-skill
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── run_tasks.sh                # Binary task executor
│   │       └── validate_projects.sh        # Pre-flight check
│   └── linglong-source-updater/            # Source compilation sub-skill
│       ├── SKILL.md
│       ├── scripts/
│       │   ├── run_tasks.sh                # Source task executor (6 steps)
│       │   ├── download-and-checksum.sh    # Download + sha256 + analysis
│       │   ├── update-linglong-yaml.py     # Insert sources/build rules
│       │   └── validate-linglong-yaml.py   # Dual-mode YAML validator
│       └── references/
│           └── manifests-for-yaml.md       # linglong.yaml field spec
├── for-multica/
│   ├── agent.md                            # Multica platform adapter
│   └── agent-config.json                   # Multica config
├── example/                                # Example projects & generators
├── task-example.json                       # Reference JSON (binary + source)
└── REFACTOR-PLAN.md                        # Architecture design doc
```

### Key Files Explained

| File | Description |
|------|-------------|
| `agents/linyaps-packaging-runner.agent.md` | **Agent entry** — reads config, groups tasks by `type`, dispatches to sub-skills |
| `agent-config.json` | Global config: `projects_root`, `output_dir`, `build_tmp_dir`, `src_dir` |
| `scripts/csv_to_json.sh` | **Unified entry point** — accepts CSV or JSON, converts CSV to JSON, triggers agent dispatch |
| `scripts/common.sh` | Shared library used by all sub-skill scripts (colored output, parse_json, download, arch validation, etc.) |
| `skills/linglong-binary-runner/scripts/run_tasks.sh` | **Binary executor** — downloads sources, validates arch, runs `pak_linyaps.sh` per task |
| `skills/linglong-source-updater/scripts/run_tasks.sh` | **Source executor** — 6-step pipeline (validate → download+checksum → update YAML → build → export) |
| `skills/config/arch_mapping.json` | Maps URL arch keywords (`amd64`, `x64`, `aarch64`) to linyaps arch identifiers (`x86_64`, `arm64`) |
| `task-example.json` | Reference JSON task file with both binary and source task examples |

---

## Quick Start

### Using a CSV file

```bash
# 1. Prepare a CSV file with headers: 记录ID,包名,架构,版本,网站地址,下载地址

# 2. Preview the generated JSON (dry-run mode)
./scripts/csv_to_json.sh my-tasks.csv --dry-run

# 3. Execute packaging with your adapted projects
./scripts/csv_to_json.sh my-tasks.csv \
  --projects_root=/path/to/adapted/projects
```

### Using a JSON file

```bash
# Direct execution with a JSON task file containing type=binary tasks
./scripts/csv_to_json.sh task-example.json
```

> **Note:** Starting directly with `csv_to_json.sh` is backward compatible — it detects JSON files and passes them through.

---

## Task File Formats

### JSON Format

A JSON task file contains a `global` configuration block and a `tasks` array:

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

#### Global Configuration

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `projects_root` | **Yes** | — | Root directory containing adapted packaging projects |
| `output_dir` | No | `./output` | Directory for build outputs |
| `build_tmp_dir` | No | *(auto-generated)* | Build cache directory |
| `src_dir` | No | `./src` | Directory for downloaded source packages |

#### Task Entry Fields

| Field | Required | Description |
|-------|----------|-------------|
| `pkgName` | **Yes** | Package name, used to locate project directory (e.g., `com.opera.browser`) |
| `type` | No | Task type: `binary` (default) or `source` |
| `src_url` | **Yes** | Upstream source download URL |
| `arch` | **Yes** | Target architecture: `x86_64` or `arm64` |
| `orig_version` | No | Upstream version string; auto-extracted from `src_url` if empty |
| `kind` | Source only | Source kind: `archive`, `git`, `file`, `dsc` (default: `archive`) |
| `name` | Source only | Source name field in linglong.yaml `sources` entry (default: `src`) |

**Optional: Version Extraction Patterns** (top-level `version_extract_examples`):

When `orig_version` is empty, the script matches `src_url` against these regex patterns to extract the version automatically. See `agent-config.json` for examples.

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
| `版本` | `orig_version` | No | Upstream version; auto-extracted from URL if empty |
| `网站地址` | *(ignored)* | No | Project homepage, not used |
| `下载地址` | `src_url` | **Yes** | Upstream source download URL |

> **Note:** CSV tasks are treated as `type=binary` by default. For source tasks, use JSON format with `"type": "source"`.

#### Data Cleaning

The converter automatically handles:
- **Whitespace trimming**: Leading/trailing spaces and tabs removed
- **Header aliases**: Both simplified (下载地址) and traditional (下載地址) Chinese headers accepted
- **Row skipping**: Rows missing required fields silently skipped

#### Global Configuration for CSV

Since CSV files have no `global` section, configuration is provided via:

1. **Command-line arguments** (highest priority):
   ```bash
   ./scripts/csv_to_json.sh tasks.csv \
     --projects_root=/path/to/projects \
     --output_dir=./output
   ```

2. **JSON config file** (`--config`):
   ```bash
   ./scripts/csv_to_json.sh tasks.csv --config=global_config.json
   ```

3. **Default values** (lowest priority):
   | Parameter | Default |
   |-----------|---------|
   | `projects_root` | `./projects` |
   | `output_dir` | `./output` |
   | `build_tmp_dir` | *(auto-generated)* |
   | `src_dir` | `./src` |

---

## Task Types

### Binary (default)

- **Entry point**: `pak_linyaps.sh`
- **Scope**: Pre-adapted packaging projects (project directory contains `pak_linyaps.sh` + `templates/linglong.yaml`)
- **Sub-skill**: `linglong-binary-runner`
- **Execution**: Download source → validate arch → locate project → run `pak_linyaps.sh`
- **Constraint**: Must NOT modify `linglong.yaml` or call `ll-builder` directly

### Source

- **Entry point**: `ll-builder build` + `ll-builder export`
- **Scope**: Source projects with a `linglong.yaml` (but no `pak_linyaps.sh`)
- **Sub-skill**: `linglong-source-updater`
- **Execution**: 6-step pipeline — validate → download+checksum → update YAML → validate output → build → export
- **Constraint**: Input `linglong.yaml` must pass pre-validation (no `sources` section); build rules must use `${PREFIX}` paths

---

## Command-Line Reference

### csv_to_json.sh

**Unified entry point** — accepts both CSV and JSON files, converts CSV to JSON, then triggers the agent dispatch flow.

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
- **CSV input** → Converts to JSON → Agent dispatches tasks by type
- **JSON input** → Passes through directly to agent dispatch

---

## Execution Flow

```
┌──────────────────────────────────────────────────────────────┐
│  1. Load Configuration                                       │
│     agent-config.json → global settings + version patterns   │
├──────────────────────────────────────────────────────────────┤
│  2. Parse & Initialize                                       │
│     CSV → csv_to_json.sh → JSON                              │
│     JSON → direct use                                        │
│     Create: src_dir, output_dir, build_tmp_dir               │
├──────────────────────────────────────────────────────────────┤
│  3. Dispatch by Type (Agent Phase)                           │
│     ┌──────────────────────────────────────────────────┐     │
│     │ Group tasks by tasks[].type (default: "binary")   │     │
│     │ Write subtask JSON for each group                  │     │
│     │ Call sub-skill:                                     │     │
│     │   binary → linglong-binary-runner                  │     │
│     │   source → linglong-source-updater                 │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  4. Binary Execution (per task)                              │
│     ┌──────────────────────────────────────────────────┐     │
│     │ a. Extract version from URL (if empty)            │     │
│     │ b. Validate architecture (URL vs declared arch)   │     │
│     │ c. Download source package                        │     │
│     │ d. Locate project (CI_ll_<pkgName> / <pkgName>)  │     │
│     │ e. Detect --build_tmp_dir support                 │     │
│     │ f. Execute pak_linyaps.sh                         │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  5. Source Execution (6 steps per task)                      │
│     ┌──────────────────────────────────────────────────┐     │
│     │ S-1: Validate input linglong.yaml (no sources)    │     │
│     │ S-2: Download + sha256 + directory analysis       │     │
│     │ S-3: Insert sources + fix build rules in YAML     │     │
│     │ S-4: Validate output linglong.yaml (has sources)  │     │
│     │ S-5: ll-builder build                             │     │
│     │ S-6: ll-builder export → move .layer to output    │     │
│     └──────────────────────────────────────────────────┘     │
├──────────────────────────────────────────────────────────────┤
│  6. Output Summary                                           │
│     Total / Success / Fail counts + per-task details         │
└──────────────────────────────────────────────────────────────┘
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

## Troubleshooting

### "找不到項目目錄" (Project directory not found)

The script looks for project directories under `projects_root` in this order:
1. `CI_ll_<pkgName>/pak_linyaps.sh`
2. `<pkgName>/pak_linyaps.sh`
3. Fuzzy match: any directory containing `<pkgName>` with a `pak_linyaps.sh`

**Solution**: Ensure your adapted projects are in `projects_root` and follow the `CI_ll_<pkgName>` naming convention.

### "架構不匹配" (Architecture mismatch)

The URL contains architecture keywords that contradict the declared `arch` field.

**Solution**: Verify the `arch` field in your task file matches the actual package architecture. Check `skills/config/arch_mapping.json` for supported mappings.

### "無法從 URL 提取版本號" (Cannot extract version from URL)

The `orig_version` field is empty and the URL doesn't match any known version pattern.

**Solution**: Explicitly set `orig_version` in your task file, or add a new pattern to `version_extract_examples` in `agent-config.json`.

### "CSV 缺少必要欄位" (CSV missing required columns)

The CSV file is missing one or more of: `包名`, `下载地址`, `架构`.

**Solution**: Ensure your CSV file includes the header row with all required columns.

### Download fails for redirect URLs

Some URLs (e.g., VS Code's `update.code.visualstudio.com/latest/...`) require redirect following.

**Solution**: The script automatically handles redirects via `curl -L`. If issues persist, pre-download the file and use a direct URL.

---

## Notes

- **`--build_tmp_dir` support is not universal**: The script auto-detects whether a project's `pak_linyaps.sh` supports this parameter. If unsupported, the parameter is silently omitted.
- **Execution permissions**: Ensure `pak_linyaps.sh` scripts have execute permission (`chmod +x`).
- **UTF-8 encoding**: CSV files must be UTF-8 encoded. Both simplified and traditional Chinese headers are supported.
- **Concurrent execution**: Tasks run sequentially. For parallel execution, split your task file and run multiple instances with separate `output_dir` and `build_tmp_dir` values.
- **Backward compatibility**: `csv_to_json.sh` transparently handles JSON files as a single unified entry point.
- **Symbolic link setup**: When using this repo as an opencode skill, set up `.opencode/` symlinks as described in `REFACTOR-PLAN.md`.
