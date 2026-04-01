---
name: skill-creator
description: Create new skills, modify and improve existing skills, and measure skill performance. Use when users want to create a skill from scratch, edit, or optimize an existing skill, run evals to test a skill, benchmark skill performance with variance analysis, or optimize a skill's description for better triggering accuracy.
---

# Skill Creator

A skill for creating new skills and iteratively improving them.

At a high level, the process of creating a skill goes like this:

- Decide what you want the skill to do and roughly how it should do it
- Write a draft of the skill
- Create a few test prompts and simulate running them (with vs. without the skill instructions)
- Help the user evaluate the results both qualitatively and quantitatively
  - While reviewing, draft quantitative assertions if there aren't any
  - Use `eval-viewer/generate_review.py` to generate a static HTML viewer for the user to review results and leave feedback
- Rewrite the skill based on the user's feedback
- Repeat until satisfied

Your job is to figure out where the user is in this process and jump in to help them progress through these stages. Maybe they say "I want to make a skill for X" — help narrow down the intent, write a draft, write test cases, evaluate, and repeat. Or maybe they already have a draft — go straight to the eval/iterate part.

Always be flexible. If the user says "skip the evals, just vibe with me", do that instead.

---

## Platform Context: Clacky

This skill runs inside **Clacky** (openclacky). Key platform specifics:

- **Skills** live at `~/.clacky/skills/<skill-name>/` — **always create new skills here** (global user skills, visible to Web UI and all sessions). To locate an existing skill, check these paths in order using `glob` or `ls`: (1) `.clacky/skills/` — project-level skills, (2) `~/.clacky/skills/` — user-level skills. Built-in skills (shipped with the gem) are always available via `invoke_skill` by name — no file lookup needed. Never use `find /` or broad filesystem searches to locate skills.
- **No parallel subagents** — Clacky runs as a single agent; all test cases execute serially in the current session
- **No external agent CLI** — for evals, just execute the task directly in-session (read the skill, follow instructions, save outputs)
- **Scripts** — prefer **Ruby** (`.rb` files); Clacky is Ruby-native. Run with `ruby path/to/script.rb`. Python is available but Ruby is the default choice
- **`python3`** — if Python scripts are needed (e.g., `generate_review.py`), use `python3` explicitly
- The description optimization scripts (`run_loop.py`, `run_eval.py`) work in Clacky — they use `clacky agent --json` to detect `invoke_skill` events. See the Description Optimization section for usage

---

## Communicating with the user

Pay attention to context cues to understand how technical the user is. In general:

- "evaluation" and "benchmark" are fine
- For "JSON" and "assertion" — explain briefly if you're unsure the user knows these terms

It's always OK to briefly explain a term if you're in doubt.

---

## Creating a skill

### Capture Intent

Start by understanding what the user wants. If the current conversation already shows a workflow they want to capture (tools used, sequence of steps, corrections made, input/output formats), extract answers from history first — the user may just need to fill gaps and confirm.

1. What should this skill enable Clacky to do?
2. When should this skill trigger? (what phrases/contexts)
3. What's the expected output format?
4. Should we set up test cases? Skills with objectively verifiable outputs (file transforms, data extraction, code generation) benefit from test cases. Skills with subjective outputs (writing style, creative work) often don't need them.

### Interview and Research

Ask about edge cases, input/output formats, example files, success criteria, and dependencies before writing test prompts. Come prepared with context to reduce burden on the user.

### Write the SKILL.md

Components to fill in:

- **name**: Skill identifier (lowercase, hyphens OK)
- **description**: Primary triggering mechanism — include BOTH what the skill does AND specific contexts for when to use it. All "when to use" info goes here, not in the body. Make the description a little "pushy" — err toward over-triggering rather than under-triggering. Example: instead of "Helps with dashboard creation", write "Helps with dashboard creation. Use this skill whenever the user mentions dashboards, data visualization, or wants to display any kind of data, even if they don't explicitly say 'dashboard'."
- **disable-model-invocation**: Set to `false` (always include this)
- **user-invocable**: Set to `true` to make the skill appear in the WebUI chatbox `/` command list. **Always include this** — without it, users cannot manually invoke the skill from the Clacky Web UI session chat.
- **compatibility** (optional): Required tools or dependencies
- **Body**: The actual instructions

> **Clacky-specific**: Every skill MUST include `disable-model-invocation: false` and `user-invocable: true` in the YAML frontmatter, or it will be invisible in the WebUI `/` command list. The minimal valid frontmatter is:
> ```yaml
> ---
> name: my-skill
> description: 'Your description here. Avoid colons followed by a space (like "wants to: do X") inside the description — they break YAML parsing and the skill will silently fail to load. Wrap the entire description in single quotes to be safe, or rephrase to avoid the colon pattern.'
> disable-model-invocation: false
> user-invocable: true
> ---
> ```
>
> **YAML description gotcha**: If the description contains `word: value` patterns (colons followed by space), YAML treats them as key-value pairs and the frontmatter parse fails silently. Always wrap description values in single quotes. Avoid embedded double-quotes inside single-quoted strings (use rephrasing instead).

> **After writing SKILL.md — always validate and auto-fix**: Run this immediately after creating or updating any skill file:
> ```bash
> ruby SKILL_DIR/scripts/validate_skill_frontmatter.rb /path/to/new-skill/SKILL.md
> ```
> The script validates the YAML frontmatter and auto-fixes common issues (unquoted descriptions, multi-line block scalars with colons). If it prints `OK:` — you're done. If it prints `Auto-fixed and saved` — it repaired the file automatically. If it prints `ERROR` — manual fix required.

### Skill Writing Guide

#### Anatomy of a Skill

Skills are created at `~/.clacky/skills/<skill-name>/`:

```
~/.clacky/skills/skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name, description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/    - Executable code (prefer .rb Ruby scripts)
    ├── references/ - Docs loaded into context as needed
    └── assets/     - Files used in output (templates, icons, fonts)
```

#### Progressive Disclosure

Skills use a three-level loading system:
1. **Metadata** (name + description) — Always in context (~100 words)
2. **SKILL.md body** — In context whenever skill triggers (<500 lines ideal)
3. **Bundled resources** — Loaded as needed (unlimited)

**Key patterns:**
- Keep SKILL.md under 500 lines; if approaching the limit, extract content into `references/` files and add clear pointers
- Reference files from SKILL.md with guidance on when to read them
- For large reference files (>300 lines), include a table of contents

**Domain organization** — When a skill supports multiple frameworks/domains, organize by variant:
```
my-skill/
├── SKILL.md (workflow + which reference to load)
└── references/
    ├── rails.md
    ├── django.md
    └── express.md
```

#### Bundled Scripts (Ruby preferred)

When a skill needs to execute code — API calls, file processing, data transforms — bundle a Ruby script instead of writing inline shell commands. This is cleaner, reusable, and more maintainable.

**Ruby script template:**
```ruby
#!/usr/bin/env ruby
# skill-name/scripts/do_something.rb
# Usage: ruby path/to/do_something.rb [args]

require 'net/http'
require 'json'
require 'fileutils'

# Read args
input = ARGV[0]
if input.nil? || input.strip.empty?
  warn "Usage: ruby do_something.rb <input>"
  exit 1
end

# ... logic ...

puts result  # stdout is the output
```

Invoke from SKILL.md by referencing the script via the Supporting Files block — at runtime, the AI receives the full absolute path of every supporting file. Refer to it as `SKILL_DIR` in instructions so the AI substitutes the correct path from the Supporting Files list:

```bash
ruby "SKILL_DIR/scripts/do_something.rb" "argument"
```

Never hardcode paths like `~/.clacky/skills/my-skill/scripts/...` — they break when the skill is installed at a different location. Never use `find` to locate scripts — the Supporting Files block always provides the correct absolute paths.

Ruby standard library covers most needs (`net/http`, `json`, `fileutils`, `uri`, `time`). No gems needed for basic API calls.

#### Principle of Least Surprise

Skills must not contain malware, exploit code, or anything that could compromise security. A skill's contents should not surprise the user if described. Don't create misleading skills or skills designed for unauthorized access or data exfiltration.

#### Writing Patterns

Use the imperative form in instructions.

**Defining output formats:**
```markdown
## Report structure
Use this exact template:
# [Title]
## Executive summary
## Key findings
## Recommendations
```

**Examples pattern:**
```markdown
## Commit message format
**Example 1:**
Input: Added user authentication with JWT tokens
Output: feat(auth): implement JWT-based authentication
```

### Writing Style

Explain *why* things are important rather than just issuing commands. Use theory of mind — make the skill general, not over-fitted to specific examples. Write a draft, then look at it with fresh eyes and improve it. If you find yourself writing ALWAYS or NEVER in all caps, that's a yellow flag — try to reframe as an explanation of why, so the agent understands the reasoning rather than just following a rule.

### Test Cases

After writing the skill draft, come up with 2–3 realistic test prompts — the kind of thing a real user would actually say. Share them with the user for review, then run them.

Save test cases to `evals/evals.json`:

```json
{
  "skill_name": "example-skill",
  "evals": [
    {
      "id": 1,
      "prompt": "User's task prompt",
      "expected_output": "Description of expected result",
      "files": []
    }
  ]
}
```

Don't write assertions yet — just the prompts. Add assertions in the next step.

See `references/schemas.md` for the full schema.

---

## Running and Evaluating Test Cases

This is one continuous sequence — don't stop partway through.

Since Clacky has no subagents, run test cases **serially** in the current session. For each test case, simulate two runs:

- **with_skill**: Read the SKILL.md, then follow its instructions to complete the task
- **without_skill**: Complete the same task using only general knowledge (no skill instructions)

Put results in `<skill-name>-workspace/` as a sibling to the skill directory. Organize by iteration (`iteration-1/`, `iteration-2/`, etc.), and within that by test case (use descriptive names like `eval-create-report`, not `eval-0`).

### Step 1: For each test case, create the eval directory and run both variants

```
<skill-name>-workspace/
└── iteration-1/
    ├── eval-<descriptive-name>/
    │   ├── eval_metadata.json
    │   ├── with_skill/
    │   │   ├── outputs/        ← files produced
    │   │   └── grading.json    ← filled in later
    │   └── without_skill/
    │       ├── outputs/
    │       └── grading.json
    └── benchmark.json          ← filled in after all evals
```

Write `eval_metadata.json` for each test case:
```json
{
  "eval_id": 1,
  "eval_name": "descriptive-name",
  "prompt": "The task prompt",
  "assertions": []
}
```

**Running a with_skill eval**: Read the skill's SKILL.md fully, then execute the task as instructed by the skill — create files, run scripts, write outputs to `with_skill/outputs/`.

**Running a without_skill eval**: Execute the same task using only general knowledge. Write outputs to `without_skill/outputs/`. This is the baseline.

### Step 2: Draft assertions while running

Don't wait until all runs finish — draft quantitative assertions as you go and explain them to the user.

Good assertions are **objectively verifiable** and **descriptively named** — someone glancing at the benchmark should immediately understand what each one checks. Subjective skills are better evaluated qualitatively; don't force assertions onto things that need human judgment.

Update `eval_metadata.json` with assertions once drafted. Also update `evals/evals.json`.

### Step 3: Grade each run

For each run, evaluate assertions against the outputs. Save results to `grading.json` in each run directory.

The `grading.json` format (exact field names matter for the viewer):
```json
{
  "eval_id": 1,
  "configuration": "with_skill",
  "expectations": [
    {
      "text": "The script uses absolute paths",
      "passed": true,
      "evidence": "Script uses $HOME/... throughout"
    }
  ],
  "pass_count": 1,
  "total_count": 1,
  "pass_rate": 1.0
}
```

For assertions that can be checked programmatically, write and run a Ruby script — it's faster and more reliable than eyeballing:

```ruby
#!/usr/bin/env ruby
# Check assertion: output file contains expected content
output = File.read("with_skill/outputs/result.md")
puts output.include?("expected phrase") ? "PASS" : "FAIL"
```

### Step 4: Aggregate into benchmark

Create `benchmark.json` in the iteration directory. List `with_skill` before `without_skill` for each eval:

```json
{
  "skill_name": "my-skill",
  "iteration": 1,
  "configurations": [
    {
      "name": "with_skill",
      "label": "With skill",
      "evals": [
        {"eval_id": 1, "eval_name": "eval-name", "pass_rate": 1.0, "pass_count": 3, "total_count": 3}
      ],
      "overall_pass_rate": 1.0,
      "total_pass": 3,
      "total_assertions": 3
    },
    {
      "name": "without_skill",
      "label": "Without skill (baseline)",
      "evals": [
        {"eval_id": 1, "eval_name": "eval-name", "pass_rate": 0.33, "pass_count": 1, "total_count": 3}
      ],
      "overall_pass_rate": 0.33,
      "total_pass": 1,
      "total_assertions": 3
    }
  ],
  "delta": {
    "pass_rate_improvement": 0.67,
    "summary": "With skill: 100% | Without skill: 33% | Delta: +67pp"
  },
  "analyst_observations": [
    "..."
  ]
}
```

Or run the aggregation script (from the skill-creator directory):
```bash
python3 -m scripts.aggregate_benchmark <workspace>/iteration-N --skill-name <name>
```

### Step 5: Do an analyst pass

Read the benchmark data and surface patterns the aggregate stats might hide. See `agents/analyzer.md` for what to look for — things like assertions that always pass regardless of skill (non-discriminating), high-variance evals, and time/effort tradeoffs.

### Step 6: Generate the eval viewer — ALWAYS DO THIS BEFORE REVISING THE SKILL

**Generate the viewer first. Get the outputs in front of the user before making any changes.**

```bash
python3 <skill-creator-path>/eval-viewer/generate_review.py \
  <workspace>/iteration-N \
  --skill-name "my-skill" \
  --benchmark <workspace>/iteration-N/benchmark.json \
  --static /tmp/<skill-name>-review.html

open /tmp/<skill-name>-review.html
```

For iteration 2+, also pass `--previous-workspace <workspace>/iteration-<N-1>`.

Tell the user: "I've opened the results in your browser. 'Outputs' tab lets you click through each test case and leave feedback; 'Benchmark' shows the quantitative comparison. When you're done, come back and let me know."

### What the user sees in the viewer

**Outputs tab**: One test case at a time.
- Prompt, output files (rendered inline where possible)
- Previous output (iteration 2+, collapsed)
- Formal grades (collapsed)
- Feedback textbox (auto-saves)
- Previous feedback (iteration 2+)

**Benchmark tab**: Pass rates, per-eval breakdowns, analyst observations.

Navigation: prev/next buttons or arrow keys. "Submit All Reviews" saves to `feedback.json`.

### Step 7: Read the feedback

When the user says they're done, read `feedback.json`:

```json
{
  "reviews": [
    {"run_id": "eval-0-with_skill", "feedback": "missing axis labels on chart", "timestamp": "..."},
    {"run_id": "eval-1-with_skill", "feedback": "", "timestamp": "..."}
  ],
  "status": "complete"
}
```

Empty feedback = user was happy with that test case. Focus on cases with specific complaints.

---

## Improving the Skill

This is the heart of the loop. You've run tests, the user reviewed results — now make the skill better.

### How to think about improvements

**Generalize from feedback.** You're iterating on a few examples, but the skill will be used across thousands of different prompts. Avoid overfitting to specific examples. If there's a stubborn issue, try different metaphors or different approaches rather than adding more rigid rules.

**Keep it lean.** Remove things that aren't pulling their weight. Read the execution trace, not just the final output — if the skill is making the agent waste time on unproductive steps, cut those parts.

**Explain the why.** Try hard to explain *why* each instruction matters. Agents are smart — they perform better when they understand the reasoning rather than following rules blindly. If you find yourself writing ALWAYS or NEVER in all caps, reframe it as an explanation.

**Look for repeated work.** If every test case resulted in writing similar helper logic (e.g., an API call setup, a file parser), that's a signal to bundle a reusable Ruby script into `scripts/` and tell the skill to use it.

### The iteration loop

1. Apply improvements to the skill
2. Re-run all test cases into a new `iteration-<N+1>/` directory (with_skill and without_skill)
3. Generate the viewer with `--previous-workspace` pointing at the previous iteration
4. Wait for the user to review and tell you they're done
5. Read the new feedback, improve again, repeat

Keep going until:
- The user says they're happy
- Feedback is all empty
- You're not making meaningful progress

---

## Advanced: Blind Comparison

For more rigorous comparison, read `agents/comparator.md` and `agents/analyzer.md`. Optional — the human review loop is usually sufficient.

---

## Description Optimization

The `description` field in SKILL.md frontmatter is the primary triggering mechanism. After creating or improving a skill, offer to optimize it.

> **Clacky note**: `run_eval.py` and `run_loop.py` have been adapted for Clacky. They use `clacky agent --json` (NDJSON streaming) to detect `invoke_skill` tool calls targeting temp skills in `~/.clacky/skills/`. Queries run **serially** (single agent). `improve_description.py` calls the LLM directly via OpenRouter using `~/.clacky/config.yml` credentials.

### Manual description optimization

**Step 1: Generate trigger eval queries**

Create 20 eval queries — a mix of should-trigger and should-not-trigger. Save as JSON:

```json
[
  {"query": "the user prompt", "should_trigger": true},
  {"query": "another prompt", "should_trigger": false}
]
```

Queries must be realistic — concrete, specific, with enough context that a real user would actually say them. Include file paths, personal context, column names, backstory. Use a mix of lengths and styles (casual, formal, typos, abbreviations). Focus on edge cases.

Bad: `"Format this data"`, `"Extract text from PDF"`, `"Create a chart"`

Good: `"ok so my boss just sent me this xlsx file (its in downloads, called Q4 sales final FINAL v2.xlsx) and she wants me to add a column showing profit margin. Revenue is column C, costs in column D i think"`

**Should-trigger queries (8–10):** Different phrasings of the same intent — some formal, some casual. Include cases where the user doesn't explicitly name the skill but clearly needs it. Uncommon use cases, and cases where this skill competes with another but should win.

**Should-not-trigger queries (8–10):** Near-misses — queries that share keywords but actually need something different. The negative cases should be genuinely tricky, not obviously irrelevant ("write a fibonacci function" as a negative for a PDF skill is too easy).

**Step 2: Review with user**

Use the HTML template in `assets/eval_review.html`:
1. Read the template
2. Replace `__EVAL_DATA_PLACEHOLDER__` with the JSON array, `__SKILL_NAME_PLACEHOLDER__` with the skill name, `__SKILL_DESCRIPTION_PLACEHOLDER__` with the current description
3. Write to `/tmp/eval_review_<skill-name>.html` and `open` it
4. User edits queries, toggles should-trigger, clicks "Export Eval Set"
5. File downloads to `~/Downloads/eval_set.json`

**Step 3: Run automated optimization (recommended)**

Use the scripts from the skill-creator `scripts/` directory. Run from the skill-creator root:

```bash
# Single eval run — check current description pass rate
python3 -m scripts.run_eval \
  --eval-set ~/Downloads/eval_set.json \
  --skill-path ~/.clacky/skills/my-skill \
  --verbose

# Full optimize loop — auto-improves description over N iterations
python3 -m scripts.run_loop \
  --eval-set ~/Downloads/eval_set.json \
  --skill-path ~/.clacky/skills/my-skill \
  --max-iterations 5 \
  --runs-per-query 1 \
  --verbose
  # Outputs: best description + HTML report (auto-opens in browser)
```

Notes:
- **No `--num-workers`** needed (or it's ignored) — Clacky runs queries serially
- **No `--model`** needed — uses the model from `~/.clacky/config.yml` automatically
- Temp skills are written to `~/.clacky/skills/` and cleaned up after each query
- Each query spawns a fresh `clacky agent --json` process to avoid session contamination

**Step 3 (manual fallback)**

If scripts fail, manually iterate: for each query in the eval set, judge whether the description would trigger. Tally passes/fails. Write improved description targeting failures. Repeat 2–3 times.

Focus on:
- Failing should-trigger queries → description is too narrow; broaden the trigger language
- Failing should-not-trigger queries → description is too broad; tighten specificity

**Step 4: Apply the result**

Update the skill's SKILL.md frontmatter with the improved description. Show the user before/after.

### How skill triggering works

Skills appear in Clacky's `available_skills` list. The agent consults a skill based on the description match — but only for tasks it can't handle alone. Simple, one-step queries often won't trigger even with a good description. Make eval queries substantive enough that the skill genuinely helps.

---

## Packaging

New skills are created directly in `~/.clacky/skills/<skill-name>/` — no packaging step needed. The skill is immediately available in all sessions and the Web UI.

If distributing externally, you can package it:

```bash
python3 -m scripts.package_skill <path/to/skill-folder>
```

This creates a `.skill` file. Direct the user to the resulting file path.

---

## Reference files

- `agents/grader.md` — How to evaluate assertions against outputs
- `agents/comparator.md` — How to do blind A/B comparison between two outputs
- `agents/analyzer.md` — How to analyze why one version beat another
- `references/schemas.md` — JSON structures for evals.json, grading.json, benchmark.json

---

## The core loop (summary)

1. Understand what the skill should do
2. Draft or edit the SKILL.md
3. Run test prompts — with and without the skill — and save outputs
4. **Generate the eval viewer with `generate_review.py`** so the user can review
5. Grade assertions, aggregate benchmark
6. Get user feedback, improve the skill
7. Repeat until satisfied
8. Package and deliver

Add these steps to your todo list. Specifically: **always generate the eval viewer before revising the skill** — the user's feedback is the primary signal, not your own judgment of the outputs.
