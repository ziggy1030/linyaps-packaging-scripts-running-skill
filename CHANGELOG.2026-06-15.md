# Session 修改纪要

**日期**: 2026-06-15
**主题**: Multica CLI 通知整合 + Reviewer 配置声明化 + 通用 SKILL 去平台化

---

## 概述

本次 session 分两个阶段完成了以下工作：

1. **Phase 1 — Multica CLI 通知接入**：将此前「宣告式指派」（由 Multica 平台负责 API 调用）升级为 **CLI 驱动式指派**，使 agent 可直接使用 `multica issue comment add` 发送评论通知审查者。
2. **Phase 1.5 — Reviewer 声明化**：将硬编码的 `@reviewer` 改为从 `agent-config.json` 动态读取的可配置声明，支持部署时指向具体 member。
3. **Phase 2 — 通用 SKILL 去 multica**：移除通用 `SKILL.md` 中的所有 multica 平台专属内容，使其保持平台无关性。

---

## 修改文件清单

| 文件 | 变更规模 | 说明 |
|------|---------|------|
| `SKILL.md` | ~6 处修改 → 再移除 6 处 | 先追加后移除 multica 内容，净效果：保持原始状态 |
| `for-multica/agent-config.json` | +1 字段 | 新增 `assignment.reviewer` |
| `for-multica/agent.md` | ~8 处修改 | 全面升级为 CLI 驱动 + 动态读取 reviewer |

---

## 详细变更

### 1. `for-multica/agent-config.json`

**新增字段**：在 `assignment` 区段添加 `"reviewer": "@reviewer"`

```json
{
  "assignment": {
    "agents": [ ... ],
    "members": [],
    "reviewer": "@reviewer",    // ← 新增
    "default_strategy": { ... }
  }
}
```

**效果**：
- 部署时可将 `@reviewer` 替换为具体 member 用户名（如 `@zhangsan`）
- 默认值 `@reviewer` 确保向后兼容

### 2. `for-multica/agent.md`（共 8 处修改）

#### a) 工具清单 — 新增 `multica` CLI

```
- **`multica`** — Multica 平台 CLI，用于在任务完成后发送平台评论，
  通知 `agent-config.json` 中配置的审查者
```

#### b) 智能体指派区段 — 更新指派语义

**原**:
> 全部任务完成 → 若需要审查，指派给 `reviewer` 角色的人类成员

**新**:
> 全部任务完成 → 若需要审查，指派给 `agent-config.json` 中 `assignment.reviewer` 配置的成员

#### c) multica 平台约定 — 从声明式改为 CLI 驱动

**原**:
- issue状态声明：...由 multica 平台负责实际 API 调用
- 智能体指派声明：...agent 的指派意图和目标选择逻辑

**新**:
- issue状态声明：...agent 透过 `multica issue comment add` CLI 直接发送状态评论
- 智能体指派声明：...agent 在步骤 9 使用 `multica issue comment add` 发送含 reviewer 的评论直接通知审查者。reviewer 用户名由 `agent-config.json` 的 `assignment.reviewer` 字段宣告

#### d) 步骤 9 — 新增第 5 点：发送平台评论

```bash
ISSUE_ID=$(multica issue list --limit 10 | grep -oP 'issue-\d+' | head -1)
REVIEWER=$(jq -r '.assignment.reviewer // "@reviewer"' agent-config.json)
if [ -n "$ISSUE_ID" ]; then
  multica issue comment add "$ISSUE_ID" \
    --content "${REVIEWER} 任务执行完毕，请继续跟进。结果：成功 ${success_count} / 失败 ${fail_count} / 待初始化 ${pending_count}"
fi
```

#### e) 结果处理 — 更新平台通知描述

**原**:
> 平台通知：在步骤 9 自动通过 `@reviewer` 评论通知审查者

**新**:
> 平台通知：在步骤 9 自动通过 `agent-config.json` 中配置的 reviewer 评论通知审查者

### 3. `SKILL.md`（净效果：无变化）

**Phase 1 追加内容**（后移除）：
- `## Multica CLI 整合` 整个章节（~25 行）
- 步骤 9 第 4 点「发送平台评论」bash 代码块
- 结果处理「平台通知」行
- agent-config.json 示例中的 `assignment` 区块
- 区段说明表中的 `assignment` 行
- query_upstream.sh 描述中的「（如 multica）」提及

**保留的唯一引用**：
```
--global-config=for-multica/agent-config.json \
```
这是 query_upstream.sh 示例中指向实际配置文件的路径，属于通用文档说明，非 multica 平台功能。

---

## 核心架构变更

```
Phase 1: 声明式指派 → CLI 驱动式指派
  ┌─────────────────────────────┐
  │ 之前：由 multica 平台负责    │
  │       实际的 API 调用        │
  └──────────┬──────────────────┘
             ↓
  ┌─────────────────────────────┐
  │ 之后：agent 直接使用 CLI     │
  │     multica issue comment   │
  │     add 发送评论通知         │
  └─────────────────────────────┘

Phase 1.5: 硬编码 → 声明式配置
  ┌─────────────────────────────┐
  │ 之前：@reviewer 在正文硬编码 │
  └──────────┬──────────────────┘
             ↓
  ┌─────────────────────────────┐
  │ 之后：agent-config.json      │
  │     assignment.reviewer      │
  │     → bash 中 jq 动态读取    │
  └─────────────────────────────┘

Phase 2: 通用 SKILL 去平台化
  ┌─────────────────────────────┐
  │ 之前：SKILL.md 含 multica    │
  │       CLI 整合专属章节       │
  └──────────┬──────────────────┘
             ↓
  ┌─────────────────────────────┐
  │ 之后：SKILL.md 纯通用版本    │
  │     不含任何平台专属内容      │
  │     multica 内容仅在         │
  │     for-multica/ 目录下      │
  └─────────────────────────────┘
```

---

## 职责边界

| 文件 | 定位 | 包含内容 |
|------|------|---------|
| `SKILL.md` | 通用 SKILL（平台无关） | linyaps 打包流程，无 multica 引用 |
| `for-multica/agent.md` | Multica 专用 Agent | agent-config.json 配置、multica CLI 调用、reviewer 声明化配置 |
| `for-multica/agent-config.json` | Multica 配置 | assignment 策略、reviewer 用户、agents/members 定义 |

---

## 验证结果

- ✅ `agent-config.json` — JSON 格式有效（`python3 -m json.tool` 验证通过）
- ✅ `for-multica/agent.md` — 无 lint 错误
- ✅ `SKILL.md` — 仅剩余预存在的 skill 名称警告（非本次引入）
- ✅ 通用 `SKILL.md` 无 `multica` / `@reviewer` 残留
- ✅ 所有 `@reviewer` 硬编码已在 `for-multica/agent.md` 中替换为动态 `jq` 读取
