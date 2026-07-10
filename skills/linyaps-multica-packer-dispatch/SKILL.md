---
name: linyaps-multica-packer-dispatch
description: >
  【Packer 节点专用 / Multica 平台】指派分发 SKILL。
  由 linyaps-packer-1/linyaps-packer-2 在打包过程中调用，用于：
  (1) detect_init_source — 检测当前任务是否由 init 节点触发；
  (2) dispatch_project_not_found — 项目未适配时向 init-tracker / linyaps-src-init 发起指派；
  (3) update_issue_status — 汇总后更新 issue 状态。
  不适用于其他节点类型（init-tracker、linyaps-src-init 等）。
argument-hint: '<action> <params>'
user-invocable: false
---

# linyaps Packer 节点指派分发 SKILL

由 `linyaps-packer-1` / `linyaps-packer-2` 在打包流程中调用，负责 multica 平台上与智能体指派相关的三类操作。

## 目录约定

- 共享脚本：`skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh`
- 配置来源：`for-multica/agent-config.json` 的 `assignment` 区段
- 本 skill 脚本：`skills/linyaps-multica-packer-dispatch/scripts/`

## 三种 Action 接口

### Action 1: `detect_init_source`

检测当前打包任务是否由 `linyaps-init`（binary 初始化）或 `linyaps-src-init`（源码初始化）节点触发。

**调用时机**：packer 初始化阶段（原步骤 1.4）

**输入**：
```json
{
  "action": "detect_init_source"
}
```

**输出**：
```json
{
  "IS_INIT_ASSIGNED": false,
  "SRC_INIT_ASSIGNED": false
}
```

**消费者**：packer agent 中步骤 7.6（`status_upload.sh` vs `status_upload_initOnly.sh` 选择）

**执行逻辑**：
1. 通过 `multica issue list --limit 10` 查询当前 issue ID
2. 若获取到 ISSUE_ID，通过 `multica issue comments "$ISSUE_ID"` 获取评论
3. 优先级匹配：`linyaps-init` >> `linyaps-src-init`（binary 场景比例更高）
   - 评论包含 `linyaps-init` → `IS_INIT_ASSIGNED=true`
   - 否则包含 `linyaps-src-init` → `SRC_INIT_ASSIGNED=true`
   - 均不含 → 两者 false
4. multica CLI 不可用或查询失败 → 两标记均为 false，**不阻断流程**

### Action 2: `dispatch_project_not_found`

打包过程中项目目录未找到时，向对应初始化智能体发起指派。

**调用时机**：packer 定位项目阶段（原步骤 5）

**输入**：
```json
{
  "action": "dispatch_project_not_found",
  "pkgName": "com.example.app",
  "src_url": "https://example.com/app_1.0_amd64.deb",
  "arch": "x86_64",
  "type": "binary",
  "orig_version": "1.0"
}
```

- `type`：`"binary"` 或 `"source"`，决定指派目标

**输出**：
```json
{
  "assigned": true,
  "target_agent": "init-tracker",
  "timestamp": "2026-07-09 10:30:00",
  "agent_status": "idle"
}
```

**执行逻辑**：
1. 从 `for-multica/agent-config.json` 的 `assignment.agents[]` 筛选目标 agent：
   - `type=binary` → capabilities 包含 `project_init` 的 agent（`init-tracker`）
   - `type=source` → capabilities 包含 `src_project_init` 的 agent（`linyaps-src-init-1` / `linyaps-src-init-2`）
2. **状态检查（热备方案）**：
   ```bash
   bash skills/linyaps-multica-packer-dispatch/scripts/check-agent-status.sh \
     -w "<global.workspace 解析值>" \
     -n "<目标 agent.id>" \
     -o json
   ```
   - `idle` → 记录"目标空闲，可立即指派"
   - `busy` → 记录警告"目标繁忙，仍发起指派（由平台排队）"，**不阻断**
   - 脚本报错 → 记录警告"无法查询状态，直接发起指派"，**不阻断**
3. **指派执行**：通过 `multica issue comment add` 发送 mention 评论：
   ```bash
   ISSUE_ID=$(multica issue list --limit 10 | grep -oP 'issue-\d+' | head -1)
   if [ -n "$ISSUE_ID" ]; then
     multica issue comment add "$ISSUE_ID" \
       --content "@${TARGET_AGENT_ID} 请为 ${pkgName} 进行项目初始化适配工作（${arch}）。下载地址：${src_url}"
   fi
   ```
4. **记录指派日志**：写入 `data_dir/assignment.log`：
   ```
   assigned_init, <pkgName>, <agent_id>, <arch>, <timestamp>      # binary
   assigned_src_init, <pkgName>, <agent_id>, <arch>, source, <timestamp>  # source
   ```
5. multica CLI 不可用或查询不到 ISSUE_ID → 记录警告 `multica_unavailable, <pkgName>`，**不阻断**

### Action 3: `update_issue_status`

所有任务执行完毕后，根据统计更新 multica issue 状态。

**调用时机**：packer 完成阶段（原步骤 9）

**输入**：
```json
{
  "action": "update_issue_status",
  "success_count": 8,
  "fail_count": 1,
  "pending_count": 2,
  "src_pending_count": 1
}
```

**输出**：
```json
{
  "issue_status": "审查完成",
  "comment_id": "comment-xxx"
}
```

**执行逻辑**：
1. 根据统计判断 issue 状态：
   - 全部成功（`fail_count=0 && pending_count=0 && src_pending_count=0`）→ `"审查完成"`
   - 存在待初始化或待源码初始化任务 → `"进行中"`
   - 全部失败且无待初始化/待源码初始化 → `"阻塞"`
   - 部分失败（存在成功任务，且无待初始化） → `"部分完成"`
2. 通过 `multica issue comment add` 发送状态评论：
   ```bash
   ISSUE_ID=$(multica issue list --limit 10 | grep -oP 'issue-\d+' | head -1)
   if [ -n "$ISSUE_ID" ]; then
     multica issue comment add "$ISSUE_ID" \
       --content "结果：成功 ${success_count} / 失败 ${fail_count} / 待初始化 ${pending_count} / 待源码初始化 ${src_pending_count}"
   fi
   ```

## 指派目标配置

定义在 `for-multica/agent-config.json` 的 `assignment` 区段，本 skill **只读读取**，不自持配置。

### `assignment.agents[]`

| agent id | capabilities | 触发条件 |
|----------|-------------|---------|
| `init-tracker` | `project_init` | binary 任务找不到项目目录 |
| `linyaps-src-init-1` | `src_project_init` | source 任务找不到项目目录 |
| `linyaps-src-init-2` | `src_project_init` | source 任务找不到项目目录（热备） |

### `assignment.default_strategy`

| 场景 | handler | 目标 agent |
|------|---------|-----------|
| binary 项目未找到 | `assign-to-agent` | `init-tracker` |
| source 项目未找到 | `assign-to-agent` | `linyaps-src-init-1` |
| 构建失败 | `mark-failed` | 无（直接标记失败） |

## 约束

1. **仅 Packer 节点调用**：此 skill 不应被 init-tracker、linyaps-src-init 或其他节点类型使用
2. **与 agent-config.json 的 assignment 区段绑定**：目标 agent 列表、策略均从配置读取
3. **支持横向扩展**：`linyaps-packer-1`、`linyaps-packer-2` 均可调用，共享同一份 dispatch 逻辑
4. **`check_endpoint` 冷备未上线**：当前 `check_endpoint` 字段为 `null`，使用 `check-agent-status.sh` 脚本作为热备方案；后续上线后改由端点查询