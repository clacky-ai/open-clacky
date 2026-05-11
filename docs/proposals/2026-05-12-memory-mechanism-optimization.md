# Proposal: Memory Mechanism Optimization

**Author:** Claude (assistant)
**Date:** 2026-05-12
**Branch:** `feat/memory-optimization` (待创建)
**Status:** Proposal

---

## 1. 问题

OpenClacky 的 memory 系统有三层，但只有前两层在正常工作。

`~/.clacky/memories/` 这个目录是完全空的。long-term memory 从来没写过东西，因为触发条件太苛刻（迭代 >= 10），而且子 agent 的白名单检查过于保守，几乎每次都判定"不需要更新"。

即使 memory 里有内容，agent 也不知道什么时候该用。base_prompt 说"Do NOT recall proactively"，但 agent 根本判断不了什么算"genuinely needed"。结果就是 memory 存在但从不使用。

对比 Claude Code 的做法：
- 自动加载 CLAUDE.md 到 system prompt
- project-level memory 和当前工作目录绑定
- agent 不需要主动调用工具，相关内容已经在 prompt 里了

我们缺的是"自动注入"的机制。

---

## 2. 要做什么

让 agent **自动**获得它需要知道的上下文，而不是**被动等待**它去 recall。

具体两件事：

### 2.1 自动 Memory 注入

在 system prompt 构建时，自动从 `~/.clacky/memories/` 中选择相关文件注入。agent 不需要主动 recall，memory 会"推"到它面前。

匹配逻辑：基于 working directory 名称 + 当前任务关键词，做简单的关键词匹配。选择最相关的 1-3 个文件注入。

注入位置：在 Project rules 之后，SOUL.md 之前。

### 2.2 项目级动态 Memory

在 working directory 下维护一个 `.clacky/CLAUDE.md`，记录项目特定的知识。

SystemPromptBuilder 自动检测并加载这个文件。MemoryUpdater 在任务结束时自动更新它。用户也可以手动编辑。

这个文件支持 git 版本控制，项目切换时自动加载，比 `~/.clacky/memories/` 更贴近实际工作。

### 2.3 降低 Memory Update 门槛

- 迭代阈值从 10 降到 5
- 简化 memory update 子 agent 的白名单判断
- 添加 `/remember` 用户命令，手动触发 memory save

---

## 3. 为什么做

现在的 memory 系统形同虚设：
- `~/.clacky/memories/` 为空，没有积累任何知识
- agent 在跨任务时"失忆"，每次都要重新了解用户偏好和项目约定
- 用户明确说过的决策（比如"不用 Redis"），下个任务 agent 就忘了
- 对比 Claude Code，差了一个 automatic context loading 的层级

自动注入的好处：
- 零额外 LLM 调用，利用现有 prompt caching
- agent 不需要学习"什么时候 recall"，相关内容已经在 prompt 里
- 项目级 memory 让多项目切换时上下文不混淆

---

## 4. 准备怎么做

改动集中在三个模块：

1. **SystemPromptBuilder** — 添加 `load_relevant_memories` 方法，构建 prompt 时自动注入相关 memory 内容
2. **MemoryUpdater** — 降低迭代阈值，简化白名单，添加 `.clacky/CLAUDE.md` 写入逻辑
3. **base_prompt.md** — 更新 memory 相关规则（从"不要主动 recall"改为"相关 memory 已自动注入"）

文件范围：
- `lib/clacky/agent/system_prompt_builder.rb`
- `lib/clacky/agent/memory_updater.rb`
- `lib/clacky/agent/skill_manager.rb`
- `lib/clacky/agent.rb`（添加 `/remember` 命令）
- `lib/clacky/default_agents/base_prompt.md`

---

*End of Proposal*
