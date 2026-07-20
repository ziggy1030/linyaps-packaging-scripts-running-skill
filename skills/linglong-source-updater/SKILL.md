---
name: linglong-source-updater
description: '更新已初始化的 linglong.yaml，補充上游源碼信息，更新構建規則，並自動打包為玲瓏 layer。用於 source 類型任務（特徵：目錄下有 linglong.yaml 但缺少 sources 段）。支援 archive/git/file/dsc 四種源碼類型。'
argument-hint: '<task.json> [--agent-config-path=<path>]'
references:
  - references/manifests-for-yaml.md
user-invocable: false
---

# linyaps Source 源碼編譯打包器

當 agent 分派 `type=source` 的任務時使用此 skill。

## 目錄約定

- 執行腳本：`skills/linglong-source-updater/scripts/run_tasks.sh`
- 下載校驗腳本：`skills/linglong-source-updater/scripts/download-and-checksum.sh`
- YAML 更新腳本：`skills/linglong-source-updater/scripts/update-linglong-yaml.py`
- 格式驗證腳本：`skills/linglong-source-updater/scripts/validate-linglong-yaml.py`
- 字段規範參考：`skills/linglong-source-updater/references/manifests-for-yaml.md`
- 共享庫：`skills/linglong-source-updater/scripts/common.sh`
- 架構映射：`skills/config/arch_mapping.json`

## 使用前提

- 目標項目目錄下存在 `linglong.yaml`，且格式正確、無 sources 段
- `build` 字段中必須包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`（腳本會自動追加）
- `build` 段中所有安裝目錄參數出現 `/usr` 或 `/usr/local` 絕對路徑均為錯誤：
  - `--prefix=/usr` / `--libdir=/usr/lib` / `--bindir=/usr/bin`
  - `-DCMAKE_INSTALL_PREFIX=/usr` / `-DCMAKE_INSTALL_LIBDIR=/usr/lib`
  - `QMAKE_INSTALL_PREFIX=/usr`
  - 以上均須以 `${PREFIX}` 替代（系統命令如 `apt-get`、`dpkg` 中的 `/usr` 除外）
- 環境依賴：`ll-builder`、`python3-ruamel.yaml`、`python3-yaml`

## 輸入

標準任務 JSON，`tasks[].type` 為 `source`，並可選傳入 `--agent-config-path=<path>` 指定 `agent-config.json` 路徑：

```json
{
  "global": {
    "projects_root": "/path/to/projects",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  },
  "tasks": [
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

## 執行流程（6 步驟）

- **S-1**：輸入驗證 — `validate-linglong-yaml.py`（不帶 `--allow-sources`）
- **S-2**：源碼分析 — `download-and-checksum.sh` 下載源碼、計算 sha256、分析目錄
- **S-3**：YAML 更新 — `update-linglong-yaml.py` 插入 sources 段、修正 build
- **S-4**：輸出驗證 — `validate-linglong-yaml.py`（帶 `--allow-sources`）
- **S-5**：構建 — `ll-builder build`
- **S-6**：導出 — `ll-builder export --layer --no-develop -z zstd`，移動 .layer 到 output_dir

## 約束

- 使用 `ll-builder build` + `ll-builder export` 進行源碼編譯打包，不依賴 `pak_linyaps.sh`
- 輸入的 `linglong.yaml` 必須通過 validate 檢測（無 sources 段）
- `build` 段必須包含 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
- `${PREFIX} 安裝目錄約束`：`build` 段中所有安裝目錄參數出現 `/usr` 或 `/usr/local` 絕對路徑均為錯誤（如 `--prefix=/usr`、`--libdir=/usr/lib`、`-DCMAKE_INSTALL_LIBDIR=/usr/lib`、`QMAKE_INSTALL_PREFIX=/usr`），必須以 `${PREFIX}` 替代；系統命令中的 `/usr` 除外
- `build` 第一个步骤必须进入源码目录，使用 `export SRC_ROOT=$(ls -d /project/linglong/sources/<name>/*)` 动态发现后 `cd ${SRC_ROOT}`（适用于 archive/git/dsc）。`<name>` 对应 sources 段的 `name` 属性。
> 参考示例：`examples/CI_ll_org.mamedev.mamedev.linglong.yaml` L132-L134
