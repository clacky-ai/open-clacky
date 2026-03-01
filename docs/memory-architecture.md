# Agent 记忆架构：主动写入 vs 记忆压缩

> **目标读者**：想在自己的 Agent 项目中复用 OpenClaw 记忆架构的开发者。
>
> **适用场景**：基于 LLM 的长期运行 Agent，需要跨 session 保留知识、同时管理上下文窗口溢出。

---

## 一、两套机制概览

OpenClaw 的"记忆"由两个**完全独立、互相补充**的机制构成：

| 机制 | 核心目标 | 存储位置 | 跨 Session |
|---|---|---|---|
| **主动写入 MEMORY.md** | 知识持久化 | 磁盘 `.md` 文件 | ✅ 永久保留 |
| **Compaction（记忆压缩）** | 上下文窗口管理 | 内存消息历史（in-memory） | ❌ session 结束即消失 |

---

## 二、主动写入 MEMORY.md

### 2.1 提示词来源

**写入指令**不在代码里硬编码，而是来自 workspace 的 `AGENTS.md` 文件。  
Session 启动时，系统通过以下链路将 `AGENTS.md` 注入系统提示词：

```
resolveBootstrapContextForRun()
  └─ buildBootstrapContextFiles()
       └─ contextFiles[]
            └─ 注入到系统提示词的 "# Project Context" 段落
```

**只有读取指令**被硬编码在 `system-prompt.ts` 的 `buildMemorySection()` 里：

```
## Memory Recall
Before answering anything about prior work, decisions, dates, people, preferences,
or todos: run memory_search on MEMORY.md + memory/*.md; then use memory_get to pull
only the needed lines.
```

> 结论：**读的提示词 → 代码硬编码**，**写的提示词 → AGENTS.md（用户可自定义）**。

---

### 2.2 AGENTS.md 写入指令原文

以下是 `docs/reference/templates/AGENTS.md` 的核心记忆相关段落：

#### 每次 Session 开始时（强制读取）

```markdown
## Every Session

Before doing anything else:
1. Read `SOUL.md` — this is who you are
2. Read `USER.md` — this is who you're helping
3. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
4. **If in MAIN SESSION**: Also read `MEMORY.md`

Don't ask permission. Just do it.
```

#### MEMORY.md 长期记忆规则

```markdown
### 🧠 MEMORY.md - Your Long-Term Memory

- **ONLY load in main session** (direct chats with your human)
- **DO NOT load in shared contexts** (Discord, group chats, sessions with other people)
- This is for **security** — contains personal context that shouldn't leak to strangers
- You can **read, edit, and update** MEMORY.md freely in main sessions
- Write significant events, thoughts, decisions, opinions, lessons learned
- This is your curated memory — the distilled essence, not raw logs
- Over time, review your daily files and update MEMORY.md with what's worth keeping
```

#### 写入原则：禁止"心理便条"

```markdown
### 📝 Write It Down - No "Mental Notes"!

- **Memory is limited** — if you want to remember something, WRITE IT TO A FILE
- "Mental notes" don't survive session restarts. Files do.
- When someone says "remember this" → update `memory/YYYY-MM-DD.md` or relevant file
- When you learn a lesson → update AGENTS.md, TOOLS.md, or the relevant skill
```

#### Heartbeat 期间的维护任务

```markdown
### 🔄 Memory Maintenance (During Heartbeats)

1. Read through recent `memory/YYYY-MM-DD.md` files
2. Update `MEMORY.md` with distilled learnings
3. Remove outdated info from MEMORY.md that's no longer relevant

Think of it like a human reviewing their journal and updating their mental model.
Daily files are raw notes; MEMORY.md is curated wisdom.
```

---

### 2.3 记忆文件结构

```
workspace/
├── AGENTS.md          # Agent 行为指令（含写入规则），session 启动时注入系统提示词
├── SOUL.md            # Agent 的性格/价值观
├── USER.md            # 用户背景信息
├── MEMORY.md          # 长期记忆（精华，仅主 session 加载）
└── memory/
    ├── 2026-06-15.md  # 今日日志（原始记录）
    ├── 2026-06-14.md  # 昨日日志
    └── ...
```

**两层记忆设计**：
- `memory/YYYY-MM-DD.md`：**原始日志**，当天发生了什么，快速写入，不筛选
- `MEMORY.md`：**精华提炼**，LLM 主动筛选后写入，类似人类的长期记忆

---

## 三、Compaction（记忆压缩）

### 3.1 触发时机

当 context window 接近上限（token 溢出）时，系统自动触发：

```
attempt.ts（run loop）
  └─ 检测 token 超限（overflow）
       └─ compactInLane()
            └─ session.compact(customInstructions)
                 └─ generateSummary()
                      └─ 旧消息被摘要文本替换（in-memory）
```

### 3.2 核心实现

**`src/agents/compaction.ts`** 中的 `summarizeChunks()`：

```typescript
// 将消息历史分块，逐块生成摘要
async function summarizeChunks(params: {
  messages: AgentMessage[];
  model: ...;
  previousSummary?: string;
}): Promise<string> {
  // SECURITY: 工具调用结果的详情不进入摘要 LLM，防止数据泄露
  const safeMessages = stripToolResultDetails(params.messages);
  const chunks = chunkMessagesByMaxTokens(safeMessages, params.maxChunkTokens);

  let summary = params.previousSummary;
  for (const chunk of chunks) {
    summary = await generateSummary(chunk, ...);
  }
  return summary ?? "No prior history.";
}
```

**`src/agents/pi-embedded-runner/compact.ts`** 中的触发逻辑：

```typescript
const result = await compactWithSafetyTimeout(() =>
  session.compact(params.customInstructions),
);
// compaction 完成后，session.messages 中的旧消息已被摘要替换
// 注意：不写磁盘，session 结束即消失
```

### 3.3 安全设计

- `stripToolResultDetails()`：确保工具调用的详细返回值不进入摘要 LLM（防止敏感数据泄露给压缩模型）
- Compaction 生成的摘要只替换内存里的消息，**不写任何磁盘文件**

---

## 四、两套机制完整对比

| 维度 | **主动写入 MEMORY.md** | **Compaction（记忆压缩）** |
|---|---|---|
| **操作对象** | 磁盘文件（`.md`） | 内存中的消息历史 |
| **触发者** | LLM 自主决定（或用户指令） | 系统自动（token 超限） |
| **触发时机** | 任何时候 LLM 认为有意义 | context window 接近上限 |
| **存储位置** | 持久化磁盘 | in-memory，替换旧消息 |
| **跨 session** | ✅ 永久保留 | ❌ session 结束即消失 |
| **内容性质** | 精华/curated（LLM 主动筛选） | 原始对话的自动压缩摘要 |
| **可检索性** | ✅ 支持向量检索（`memory_search`） | ❌ 不可单独检索 |
| **LLM 参与** | LLM 主动调用 write/edit 工具 | 由系统调用独立摘要 LLM |
| **数据安全** | 用户控制写入内容 | `stripToolResultDetails()` 自动过滤 |
| **可自定义** | ✅ 通过 AGENTS.md 自定义规则 | ✅ 可传入 `customInstructions` |

---

## 五、架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                      当前 Session 上下文                          │
│                                                                  │
│  [系统提示词]                                                     │
│    ├─ AGENTS.md（写入规则）   ← resolveBootstrapContextForRun()   │
│    ├─ buildMemorySection()（读取规则，硬编码）                     │
│    └─ MEMORY.md 内容（主 session 才注入）                         │
│                                                                  │
│  [消息历史] [消息1][消息2]...[消息N]  ← in-memory                  │
│   ─────────────────────────────────── context window limit       │
│                                                                  │
│  ⚡ 快满了 → Compaction 触发：                                    │
│    旧消息 ──→ summarizeChunks() ──→ [摘要文本]                    │
│    [摘要] 替换旧消息（仍在 in-memory）                             │
│    ↑ 只压缩窗口，不写磁盘，session 结束消失                        │
└──────────────────────────────────────────────────────────────────┘
                              ↕ 互相独立，互相补充
┌──────────────────────────────────────────────────────────────────┐
│                      磁盘持久化记忆系统                            │
│                                                                  │
│  LLM 主动 write/edit 工具 ─────────────────────────────────────  │
│    ↓ 用户说"记住这个"                                             │
│    ↓ LLM 觉得值得保留                                            │
│    ↓ Heartbeat 定期维护                                          │
│                                                                  │
│  MEMORY.md           ← 精华长期记忆（仅主 session 读取）           │
│  memory/2026-06-15.md ← 今日原始日志                             │
│  memory/2026-06-14.md ← 昨日日志                                 │
│                                                                  │
│  chokidar watch ──→ SQLite 向量索引更新                          │
│  memory_search ──→ 下次 session 可检索                           │
└──────────────────────────────────────────────────────────────────┘
```

---

## 六、关键文件清单

| 文件 | 作用 |
|---|---|
| `docs/reference/templates/AGENTS.md` | **写入指令来源**，workspace 启动模板，包含 MEMORY.md 写入规则 |
| `src/agents/system-prompt.ts` | `buildMemorySection()`，只含**读取**指令（`## Memory Recall`） |
| `src/agents/pi-embedded-helpers/bootstrap.ts` | `buildBootstrapContextFiles()`，将 AGENTS.md 等文件注入系统提示词 |
| `src/agents/bootstrap-files.ts` | `resolveBootstrapContextForRun()`，加载 workspace bootstrap 文件 |
| `src/agents/pi-embedded-runner/compact.ts` | Compaction 入口，`session.compact()` 触发，管理上下文溢出 |
| `src/agents/compaction.ts` | `summarizeChunks()` / `summarizeWithFallback()`，LLM 摘要逻辑 |
| `src/agents/session-transcript-repair.ts` | `stripToolResultDetails()`，Compaction 安全过滤 |

---

## 七、在新项目中复用这套架构

### 7.1 最小实现方案

只需要三样东西：

```
1. AGENTS.md（写入规则）    → 告诉 LLM 什么时候、怎么写文件
2. 文件读写工具             → write / read / edit（标准文件操作工具）
3. 系统提示词中的读取指令   → 告诉 LLM 在回答前先查记忆
```

### 7.2 推荐的 AGENTS.md 写入规则模板

```markdown
## Memory Rules

### Long-Term Memory (memory.md)
- Load at session start; read, edit, update freely
- Write: significant decisions, user preferences, lessons learned, open questions
- Curated — distill from daily notes, remove outdated info

### Daily Notes (notes/YYYY-MM-DD.md)
- Raw logs of what happened today; create if missing
- Write freely; no curation needed

### Key Principle
**Memory is limited — if you want to remember something, WRITE IT TO A FILE.**
Mental notes don't survive restarts. Files do.

When user says "remember this" → update notes/YYYY-MM-DD.md and/or memory.md.
When you learn a lesson → update memory.md.
```

### 7.3 系统提示词中的读取指令

```markdown
## Memory Recall

Before answering anything about prior work, decisions, dates, people,
preferences, or todos:
1. Read memory.md for long-term context
2. Read notes/YYYY-MM-DD.md (today + yesterday) for recent context
3. Then answer using this retrieved context
```

### 7.4 Compaction 实现要点

如果你的 Agent 框架不内置 compaction，参考以下要点自己实现：

```typescript
// 伪代码：简单 compaction 实现
async function compactIfNeeded(messages: Message[], model: Model) {
  const tokens = estimateTokens(messages);
  if (tokens < contextWindow * 0.8) return messages; // 还有余量

  // 安全过滤：不把工具调用结果喂给摘要 LLM
  const safeMessages = stripSensitiveToolResults(messages);

  // 保留最近 N 条消息，其余压缩为摘要
  const toSummarize = safeMessages.slice(0, -10);
  const recent = messages.slice(-10);

  const summary = await generateSummary(toSummarize, model);
  return [{ role: "system", content: `[Previous context summary]\n${summary}` }, ...recent];
}
```

**关键安全注意**：工具调用返回的详细数据（尤其是外部 API 响应）**不应进入**摘要 LLM，避免敏感信息泄露到你可能无法控制的模型。

### 7.5 两层记忆的设计哲学

| 层级 | 文件 | 写入频率 | 内容要求 | 对应人类记忆 |
|---|---|---|---|---|
| 日志层 | `notes/YYYY-MM-DD.md` | 高频、随时 | 原始记录，不筛选 | 日记 |
| 精华层 | `memory.md` | 低频、定期整理 | 蒸馏后的关键信息 | 长期记忆 |

**为什么要两层**：高频写入保证不遗漏，低频整理保证质量。LLM 在 heartbeat（定期任务）中把日志蒸馏进长期记忆，删除过时内容，就像人类每周回顾日记、更新心智模型。

---

## 八、常见问题

**Q：为什么写入规则放 AGENTS.md 而不是硬编码在系统提示词里？**  
A：灵活性。不同 workspace 可以有不同的记忆规则（有的 Agent 记更多，有的记更少），用户可以直接编辑 AGENTS.md 调整行为，不需要改代码。

**Q：Compaction 会不会把写入 MEMORY.md 的内容也压缩掉？**  
A：不会。写入 MEMORY.md 是磁盘操作，Compaction 只压缩内存里的消息历史。MEMORY.md 的内容在下次 session 启动时会重新从磁盘加载进系统提示词，不受 Compaction 影响。

**Q：如果 MEMORY.md 本身太大怎么办？**  
A：定期在 heartbeat 任务中让 LLM 清理过时内容。OpenClaw 在 AGENTS.md 里明确要求"Remove outdated info from MEMORY.md that's no longer relevant"，这个维护任务由 LLM 自主完成。

**Q：多用户场景下 MEMORY.md 会泄露给别人吗？**  
A：OpenClaw 的设计是：MEMORY.md 只在 main session（直接对话）加载，在 Discord / 群聊等共享上下文中不加载，防止个人信息泄露给陌生人。复用时需要在系统提示词里加类似的条件判断。
