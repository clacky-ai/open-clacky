# Proposal: System Prompt Alignment with Claude Code

**Author:** Claude (assistant)  
**Date:** 2026-05-11  
**Branch:** `feat/system-prompt-alignment`  
**Status:** Proposal  
**Scope:** `lib/clacky/default_agents/base_prompt.md`, `lib/clacky/default_agents/coding/system_prompt.md`

---

## 1. Background & Motivation

OpenClacky's positioning is **"最省 Token 的开源 AI Agent，能力对齐 Claude Code"**. While the Harness layer (cache, compression, tool registry) achieves parity or better on cost metrics, the **system prompt layer** remains a significant gap.

The system prompt is the behavioral contract between the Agent and the LLM. A weak system prompt causes:
- **Suboptimal tool selection** (e.g., using `Write` for a 2-line change instead of `Edit`)
- **Token waste** (verbose explanations, unnecessary comments, redundant narration)
- **Safety issues** (destructive git operations, overly broad file staging)
- **Lower task completion rate** on complex multi-step tasks

This proposal targets the system prompt as a **high-leverage, low-risk improvement** that directly impacts both cost (fewer tokens per task) and capability (higher task completion rate).

---

## 2. Current State Analysis

### 2.1 `base_prompt.md` (Universal behavioral rules)

```
Lines: 36
Coverage: General behavior, Tool usage rules, TODO manager rules, Long-term memory
```

**What it does well:**
- TODO manager workflow is explicit and actionable
- "USE TOOLS to create/modify files" is correctly emphasized
- "glob > find" rule is present

**Critical gaps:**

| Gap | Impact | Evidence |
|-----|--------|----------|
| No `Edit > Write` priority rule | Agent rewrites entire files for small changes, wasting tokens | Common user complaint in complex refactoring tasks |
| No comment/response style rules | Verbose responses, unnecessary explanations, emoji usage | Inflates token count on every turn |
| No Git safety protocol | `git add -A`, `git commit --amend`, force push risks | Potential data loss, security issues |
| No code style guidelines | Multi-line docstrings, "added for X flow" comments | Code quality degradation over time |
| No error handling philosophy | Validates impossible scenarios, overly defensive code | Unnecessary complexity, more tokens |
| No response structure rules | "Let me..." prefixes, trailing summaries, diff narration | Poor UX, token waste |
| No task tracking discipline | Multiple in-progress tasks, missing TodoWrite updates | Task state confusion |

### 2.2 `coding/system_prompt.md` (Role definition)

```
Lines: 18
Coverage: Role description, working process
```

**What it does well:**
- Clear role definition ("AI coding assistant and technical co-founder")
- "Read existing code before making changes" is correct

**Critical gaps:**

| Gap | Impact |
|-----|--------|
| No explicit "Claude Code alignment" goal | Agent doesn't know it's competing with Claude Code on behavior |
| No file modification priorities | Same as base_prompt gap |
| No security awareness | Agent unaware of OWASP risks, injection vulnerabilities |
| No testing expectation | Agent often skips running tests after changes |
| No UI/frontend-specific rules | For fullstack tasks, lacks guidance on testing UI changes |

### 2.3 `general/system_prompt.md` (Non-coding agent)

```
Lines: 17
Coverage: General digital employee role
```

**Gaps:** Similar to coding agent but for general tasks — lacks tool usage priorities, response style, and safety guidelines.

---

## 3. Target State (Claude Code Reference)

Claude Code's system prompt is approximately **800-1200 lines** of dense behavioral rules, covering:

1. **Doing tasks** — How to interpret instructions, when to ask questions
2. **Code style** — Comment rules, naming, error handling, no emoji
3. **Tool usage** — Priorities, fallbacks, when to use which tool
4. **Git safety** — Explicit do's and don'ts
5. **Response style** — Conciseness rules, formatting, no trailing summaries
6. **Task tracking** — TodoWrite discipline, ONE in_progress rule
7. **Security** — XSS, SQL injection, command injection prevention
8. **UI/frontend** — Test before claiming success

**Key insight:** Claude Code's system prompt is not "more verbose" — it's **more precise**. Every rule is designed to reduce token waste and improve task completion rate.

---

## 4. Proposed Changes

### 4.1 `base_prompt.md` — Major Rewrite

**Keep (existing good rules):**
- "USE TOOLS to create/modify files"
- "ALWAYS use `glob` tool — NEVER use shell `find`"
- "All operations default to working directory"
- TODO manager workflow (with refinements)
- Long-term memory rules

**Add (new sections):**

#### Section: Code Style

```markdown
## Code Style

- **Default to writing no comments.** Only add one when the WHY is non-obvious: a hidden constraint, a subtle invariant, a workaround for a specific bug, or behavior that would surprise a reader.
- Don't explain WHAT the code does — well-named identifiers already do that.
- Don't reference the current task, fix, or callers ("used by X", "added for Y flow", "handles case from issue #123"). These belong in the PR description and rot as the codebase evolves.
- Never write multi-paragraph docstrings or multi-line comment blocks — one short line max.
- Only use emojis if the user explicitly requests it. Avoid emojis in all communication unless asked.
```

#### Section: File Modification Rules

```markdown
## File Modification Rules

- **ALWAYS prefer `edit` over `write`.** Use `write` only for creating entirely new files.
- When editing text from `file_reader` output, preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix.
- Ensure `old_string` is unique in the file. If not, provide a larger string with more surrounding context.
- Use `replace_all` only when you genuinely need to change every occurrence.
```

#### Section: Response Style

```markdown
## Response Style

- Keep responses short and concise. One sentence per update is almost always enough.
- When referencing specific functions or code, include `file_path:line_number`.
- Do not use a colon before tool calls (e.g., "Let me read the file:" → "Let me read the file.")
- Don't narrate your internal deliberation. User-facing text should be relevant communication, not a running commentary.
- Don't summarize what you just did at the end of every response. The user can read the diff.
- End-of-turn summary: one or two sentences. What changed and what's next. Nothing else.
```

#### Section: Git Safety Protocol

```markdown
## Git Safety Protocol

- NEVER update git config (user.name, user.email, etc.)
- NEVER run destructive commands: `git push --force`, `git reset --hard`, `git checkout .`, `git clean -f`
- NEVER skip hooks (`--no-verify`, `--no-gpg-sign`)
- When staging files, prefer `git add <specific-file>` over `git add -A` or `git add .`
- Always create NEW commits rather than amending existing ones
- Never amend published commits
```

#### Section: Error Handling Philosophy

```markdown
## Error Handling

- Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees.
- Only validate at system boundaries (user input, external APIs).
- Don't use feature flags or backwards-compatibility shims when you can just change the code.
```

#### Section: Task Tracking Discipline

```markdown
## Task Tracking

- Use `todo_manager` to plan and track work on complex tasks (3+ steps).
- Exactly ONE task must be `in_progress` at any time.
- Mark tasks complete IMMEDIATELY after finishing — don't batch completions.
- Complete current tasks before starting new ones.
```

### 4.2 `coding/system_prompt.md` — Enhancements

**Keep:** Role definition, "read existing code before making changes"

**Add:**

```markdown
## Security

- Be careful not to introduce security vulnerabilities such as command injection, XSS, SQL injection, and other OWASP top 10 vulnerabilities.
- If you notice insecure code, immediately fix it.
- Prioritize writing safe, secure, and correct code.

## Testing

- For UI or frontend changes, start the dev server and verify in a browser before reporting the task as complete.
- Type checking and test suites verify code correctness, not feature correctness — if you can't test the UI, say so explicitly rather than claiming success.

## Code Quality

- Don't add features, refactor, or introduce abstractions beyond what the task requires.
- A bug fix doesn't need surrounding cleanup; a one-shot operation doesn't need a helper.
- Three similar lines is better than a premature abstraction.
- No half-finished implementations either.
```

### 4.3 `general/system_prompt.md` — Add Tool Priorities

The general agent also needs tool usage priorities and response style rules, as it handles file operations too.

---

## 5. Evaluation Framework

This is critical: **we must prove the changes work**. The evaluation has two dimensions:

### 5.1 Quantitative Metrics

| Metric | Baseline (Current) | Target | Measurement Method |
|--------|-------------------|--------|-------------------|
| **Avg tokens per task** | TBD (measure on benchmark tasks) | -10% to -20% | Run identical prompts before/after, compare OpenRouter bill CSV |
| **Task completion rate** | TBD | +5% to +10% | Manual evaluation on 20-task benchmark suite |
| **Avg tool calls per task** | TBD | -5% to -15% | Fewer unnecessary tool calls (e.g., Write→Edit optimization) |
| **Response verbosity** | TBD | -20% to -30% | Character count of assistant messages per task |

### 5.2 Qualitative Checklist

For each benchmark task, evaluate:

- [ ] **Tool choice correctness**: Did it use Edit for small changes, Write only for new files?
- [ ] **No unnecessary comments**: Did it add explanatory comments only when WHY is non-obvious?
- [ ] **Concise responses**: Are assistant messages short and to-the-point?
- [ ] **Git safety**: Did it use `git add <file>` instead of `git add -A`?
- [ ] **No trailing summaries**: Does it avoid "In summary, I did X, Y, Z"?
- [ ] **Security awareness**: Did it catch/fix potential injection vulnerabilities?
- [ ] **Task tracking**: For complex tasks, did it use todo_manager correctly with ONE in_progress?

### 5.3 Evaluation Tasks

We will use **5 benchmark tasks** spanning different scenarios:

1. **Simple edit**: Rename a method across 3 files (tests Edit vs Write preference)
2. **Feature addition**: Add a new API endpoint with tests (tests code style, error handling philosophy)
3. **Refactoring**: Extract a helper method (tests abstraction judgment)
4. **Bug fix**: Fix an XSS vulnerability in a template (tests security awareness)
5. **Git workflow**: Make changes and prepare for commit (tests git safety)

### 5.4 A/B Test Protocol

```
For each task:
  1. Run with CURRENT system prompt (baseline)
  2. Run with NEW system prompt (treatment)
  3. Record: tokens, tool calls, completion status, qualitative score
  4. Compare metrics

Control variables:
  - Same model (claude-opus-4-7)
  - Same temperature (default)
  - Same working directory
  - Fresh session for each run
```

---

## 6. Implementation Plan

### Phase 1: Write Proposal (this document)
- [x] Analyze current system prompts
- [x] Identify gaps against Claude Code
- [x] Draft new content
- [x] Design evaluation framework

### Phase 2: Implement Changes
- [ ] Update `base_prompt.md`
- [ ] Update `coding/system_prompt.md`
- [ ] Update `general/system_prompt.md`
- [ ] Review and refine wording
- [ ] Ensure no contradictions with existing rules

### Phase 3: Evaluate
- [ ] Run 5 benchmark tasks with current prompt (baseline)
- [ ] Run 5 benchmark tasks with new prompt (treatment)
- [ ] Compile metrics comparison
- [ ] Document qualitative findings
- [ ] Decide: merge or iterate

### Phase 4: Merge or Iterate
- [ ] If metrics improve: merge to main
- [ ] If metrics don't improve: analyze why, revise, re-test

---

## 7. Risks & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| **Over-constrained prompt** | Medium | High (Agent becomes rigid) | Review by multiple humans; test on diverse tasks |
| **Conflict with existing rules** | Low | Medium | Full text search for overlapping concepts before merge |
| **Non-English user confusion** | Medium | Low | Keep rules simple; test with Chinese prompts |
| **Token savings < expected** | Medium | Low | Evaluate anyway; even small savings compound |
| **Breaking change for existing users** | Low | Medium | System prompt updates transparently; no user action needed |

---

## 8. Success Criteria

This proposal is **approved for implementation** if:

1. At least **3 out of 5 benchmark tasks** show improved qualitative scores
2. **Average tokens per task** decreases by ≥ 5%
3. No **regressions** in task completion rate
4. Code review approval from at least one maintainer

---

## 9. Appendix: Full Proposed `base_prompt.md`

See attached file in PR.

---

*End of Proposal*
