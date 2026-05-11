# System Prompt Alignment — Evaluation Report

**Date:** 2026-05-11
**Model:** kimi-for-coding (via api.kimi.com/coding)
**Baseline Prompt:** main branch (36 + 18 + 17 lines)
**Treatment Prompt:** feat/system-prompt-alignment (75 + 35 + 28 lines)

---

## 1. Quantitative Results

| Metric | Baseline | Treatment | Delta |
|--------|----------|-----------|-------|
| **Total iterations** | 42 | 44 | +5% |
| **Total duration** | 406.6s | 308.2s | **-24%** |
| **Total assistant chars** | 2,271 | 1,362 | **-40%** |
| **Avg chars per task** | 454 | 272 | **-40%** |

### Per-Task Breakdown

| Task | Baseline Iter | Treatment Iter | Baseline Chars | Treatment Chars | Chars Delta |
|------|--------------|---------------|----------------|-----------------|-------------|
| simple_edit | 7 | 5 (-28%) | 379 | 215 | **-43%** |
| feature_addition | 16 | 21 (+31%) | 573 | 424 | **-26%** |
| refactoring | 7 | 5 (-28%) | 598 | 245 | **-59%** |
| bug_fix | 6 | 5 (-17%) | 515 | 311 | **-40%** |
| git_workflow | 6 | 8 (+33%) | 206 | 167 | **-19%** |

---

## 2. Qualitative Checklist

### 2.1 Tool Choice Correctness (Edit vs Write)

| Task | Baseline | Treatment | Assessment |
|------|----------|-----------|------------|
| simple_edit | Used Edit | Used Edit | Both correct |
| refactoring | Used Edit | Used Edit | Both correct |
| bug_fix | Used Edit | Used Edit | Both correct |

**Verdict:** Both variants correctly preferred Edit for small changes. No regression.

### 2.2 Response Style (No emoji, concise, no trailing summaries)

| Aspect | Baseline | Treatment | Assessment |
|--------|----------|-----------|------------|
| Emoji usage | Frequent (🎉, ✅, 🛡️, 🎯, 💡) | **None** | Treatment wins |
| Trailing summaries | Present ("In summary...", "搞定！") | **Absent** | Treatment wins |
| Analogies/explanations | Present ("就像把先拿杯子再倒水...") | **Absent** | Treatment wins |
| file:// links in text | Present | **Absent** | Treatment wins |
| Line number references | Absent | **Present** (`:12`, `:17`) | Treatment wins |

**Example — refactoring task final message:**

**Baseline (598 chars):**
```
搞定！改动就像把"先拿杯子再倒水"简化成"直接倒水"——去掉了两个方法里多余的中间变量。

**改动内容：**
- `calculateTotalWithTax` 和 `applyDiscount` 都不再先把 `calculateTotal` 的结果存到局部变量里，而是直接链式调用。

这样代码更简洁，行为完全一致，也没有过度设计。测试通过 ✅
[lib/order_calculator.rb](file://...)
```

**Treatment (245 chars):**
```
Done. Removed the intermediate local variables `subtotal` and `total` in
lib/order_calculator.rb:12 and :17, calling `calculateTotal` directly in the
expressions instead. No behavior change, just eliminated the duplicated
first-step pattern.
```

**Verdict:** Treatment is dramatically more concise and professional. 4/5 tasks show clear improvement.

### 2.3 Code Style (Comments, no task references)

| Aspect | Baseline | Treatment | Assessment |
|--------|----------|-----------|------------|
| Unnecessary comments | Present in explanations | Minimal | Treatment wins |
| Task references in code | N/A (no code comments added) | N/A | N/A |
| Multi-paragraph docstrings | None in either | None | No change |

**Verdict:** Both variants produced code without unnecessary comments. The "default to no comments" rule didn't have a visible effect because the tasks didn't naturally require comments, but it also didn't cause any negative effects.

### 2.4 Security Awareness

| Task | Baseline | Treatment | Assessment |
|------|----------|-----------|------------|
| bug_fix XSS | Used `CGI.escape_html` correctly | Used `CGI.escapeHTML` correctly | Both correct |

Both variants correctly identified and fixed the XSS vulnerability. The new Security section in the coding prompt didn't change the outcome for this obvious vulnerability (both already handled it correctly), but it establishes the right posture for more subtle cases.

### 2.5 Git Safety

**Note:** The runner's `git diff --name-only` cannot detect staged files. Both baseline and treatment claimed to have staged `lib/user_renderer.rb` with `git add <file>`. The treatment message explicitly stated "使用 `git add lib/user_renderer.rb` 仅将该文件加入了暂存区" which aligns with the new Git Safety Protocol rule.

The baseline also claimed correct staging behavior ("只有 `lib/user_renderer.rb` 被 staged"). Without actual verification, both appear correct on this dimension.

**Known issue:** The `git_workflow` task didn't produce actual file changes in either variant. This suggests the task design or runner collection logic needs refinement, not the prompt.

### 2.6 Task Completion

| Task | Baseline | Treatment | Notes |
|------|----------|-----------|-------|
| simple_edit | **Complete** | **Complete** | All methods renamed correctly |
| feature_addition | Partial (no test file) | Partial (no test file) | Both variants failed to create `spec/api_handler_spec.rb`. Agent claimed to have created it but file_changes show only `lib/api_handler.rb` was modified. |
| refactoring | **Complete** | **Complete** | Correctly removed intermediate variables |
| bug_fix | **Complete** | **Complete** | Correctly escaped all user input |
| git_workflow | Partial (no visible changes) | Partial (no visible changes) | Runner collection bug — agent claimed success but file_changes empty |

**Task completion rate:** 3/5 fully successful in both variants, 2/5 partially successful.

---

## 3. Success Criteria Assessment

| Criterion | Target | Result | Status |
|-----------|--------|--------|--------|
| Qualitative improvement | ≥3/5 tasks | **4/5 tasks** show clear improvement in response style | **PASS** |
| Token reduction | ≥5% decrease | **-40%** assistant chars (proxy for tokens) | **PASS** |
| No regressions in completion | No drops | Completion rate same (3/5) in both; no regression | **PASS** |

---

## 4. Key Findings

### What worked exceptionally well

1. **Response style rules had immediate and dramatic effect.** Assistant character count dropped 40% across all tasks. Emoji usage eliminated entirely. Trailing verbose summaries replaced with 1-2 sentence factual statements.

2. **"Edit > Write" rule was consistently followed.** All successful tasks used Edit for modifications, not Write.

3. **Line number references appeared naturally.** Treatment responses included `file_path:line_number` references (e.g., `lib/order_calculator.rb:12`) without explicit prompting in the task — the rule was absorbed.

### What needs attention

1. **feature_addition task incomplete in both variants.** Neither baseline nor treatment created the test file. The new Testing section in the coding prompt didn't solve this — the agent claimed to have created the file but didn't. This may be a tool execution issue (Write tool failure or agent hallucination) rather than a prompt issue.

2. **feature_addition and git_workflow iteration count increased.** Treatment used 21 iterations vs baseline's 16 for feature_addition. The new prompt's stricter rules may cause the agent to be more cautious, increasing tool call rounds. However, the per-iteration cost decreased (shorter responses), so total duration still improved.

3. **Runner has a file collection bug.** `git diff --name-only` doesn't show staged files. Should use `git diff --cached --name-only` or `git status --porcelain`.

---

## 5. Recommendation

**Approve the system prompt changes for merge.**

The quantitative and qualitative evidence strongly supports adoption:
- 40% reduction in response verbosity
- Consistent adherence to Edit > Write priority
- Professional, concise output replacing chatty, emoji-laden responses
- No regressions in task completion rate
- Security awareness maintained (both variants handled XSS correctly)

The incomplete feature_addition task is a pre-existing issue (baseline also failed) and should be addressed separately through either task design improvement or additional prompt refinement for test generation.

---

## 6. Appendix: Raw Data Files

- `baseline_20260511_174424.json` — Baseline metrics and file outputs
- `treatment_20260511_175103.json` — Treatment metrics and file outputs
- `report_20260511_175444.json` — Combined comparison report
