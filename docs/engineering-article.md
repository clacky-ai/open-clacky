# Every AI Agent Feature Is a Cache Invalidation Surface

*May 19, 2026 · Yafei Lee / Founder of OpenClacky*

---

I'm Yafei Lee, founder of [OpenClacky](https://github.com/clacky-ai/openclacky), an open-source AI Agent written in Ruby. We wanted an agent with skills, memory, sub-agents, browser automation, dynamic model switching, and long-running sessions. Each of those features made prompt caching worse in a different way.

That was the real architecture problem. Not how to call an LLM, not how to add another tool, not how to orchestrate more agents — how to keep the cache prefix stable while the product keeps changing.

**Every agent feature is also a cache invalidation surface.** Skills load new system context. Peer-agent workflows fork the prefix. Browser automation adds volatile tool output. Compression rewrites history. Model switching can fragment the cache namespace unless model-specific state stays out of the system prompt. If you're building a capable agent and your cache hit rate is much lower than expected, this is probably why.

Over two years and three architecture generations (the first two failed), we converged on seven engineering decisions that let us hit 90%+ cache rates across real tasks — while keeping all those features intact. What follows is the complete story: what broke, what we tried, and what actually worked.

---

## Generation 1: RAG Everything (2024 – early 2025)

Our first agent was a textbook RAG system. We embedded the user's codebase, docs, and conversation history into a vector store. Every query went through hybrid retrieval, re-ranking, and query rewriting before the LLM saw anything.

It sounded right. It wasn't.

The index was always behind the repo. Every codebase update required re-embedding, and real-time sync was unreliable enough that we kept paying to search context that was sometimes stale.

The bigger problem was recall. 90% sounds high until an agent chains multiple steps. A wrong file in step 2 becomes a wrong edit in step 3 and a wasted retry in step 4. We guessed that something closer to 97% recall might be the minimum for an agent to be net-positive, and we were not close.

For coding agents working over local repos, we killed RAG entirely. No embeddings, no vector store, no retrieval pipeline. If the agent needs context, it reads files directly or searches with `grep`. If your documentation needs to be accessible to an agent, make it readable on a website. Don't shred it into embeddings.

---

## Generation 2: Multi-Agent Orchestration (mid-2025)

The next idea came from the SWEBench leaderboard playbook: a Planner agent, a Coder agent, a Reviewer agent, and a Tester agent, coordinated through a message bus with role-specific prompts.

We got decent SWEBench scores. The product was terrible.

Every handoff was a cache miss. Each agent had its own system prompt and cache namespace, and passing context between agents meant serializing rich state into a smaller message. Useful context was lost at the boundary, and the receiving agent had to rebuild its own prefix.

The overhead was not subtle. A task that one agent could finish in 4 minutes took 14 minutes with four. Cost was roughly 6× higher. Agents waited for each other, re-read context the previous agent had already processed, and sometimes contradicted each other. When the final output was wrong, tracing the failure through Planner → Coder → Reviewer took longer than debugging a single conversation.

SWEBench scores didn't predict user satisfaction. The failures that annoyed real users — slow iteration, lost context across handoffs, inconsistent code style — were not what the benchmark measured.

We killed role-based multi-agent orchestration. One main agent, one conversation, one cache namespace. Sub-agents survived only as isolated skill execution contexts, invoked through a single stable tool.

Two generations, same conclusion: the model is already smart enough. What it needs isn't more models, it's a better harness.

---

## The Seven Decisions

Generation 3 started from a question: *what if we optimized everything around a single agent's cache hit rate?* Not as a cost hack, but as an architectural principle. High cache hits mean the model sees consistent context, responds faster, and costs less. Every decision below serves that goal.

(The code is open source. Links to the exact files implementing each decision are at the end of this post.)

---

### Decision 1: History Growth Breaks Prefix Matching → Double Cache Markers

Prompt caching works by prefix matching. The LLM provider stores a hash of the message prefix; if your next request shares that prefix, you get the cached rate (depending on the provider, cached tokens are priced at a fraction of normal input tokens). The way you tell the provider where to cache is by placing `cache_control` markers on specific messages.

The naive approach is one marker on the last message. It breaks in three ways:

1. **History grows monotonically.** You mark message N. Next turn, message N+1 is appended. The content at the position of your old marker has changed, so it's a cache miss on the entire history.
2. **Tool call retries.** The model's last tool call errors out, or the user hits Ctrl-C. The "last message" gets discarded, and your marker vanishes with it.
3. **Mid-session model switches.** The user switches from Sonnet to Opus. You want to share as much prefix as possible across models. Any unnecessary marker movement becomes a cache miss event.

We hit problem (1) first. The fix progression is visible in our git log:

```
8ff66cc fix: cache
6ea99fe fix: prompt cache
e9a3602 feat: prompt cache works fine
7734c97 feat: try 2 point cache
```

The first three commits were incremental patches. The last one was the structural fix: **two markers instead of one.**

#### How double markers work

Every turn, we mark **two** consecutive messages, not one:

```
Turn N:    [..., msg_A, msg_B(*), msg_C(*)]
                         ↑          ↑
                    marker 1    marker 2

Turn N+1:  [..., msg_A, msg_B(*), msg_C(*), msg_D(*)]
                         ↑          ↑          ↑
                    (still there) (still there) new marker
```

On turn N+1, the provider tries to match the marker on `msg_C` and hits everything before it (system prompt + tools + full history minus the last message). We place a new marker on `msg_D` for the next turn.

This is a **rolling double buffer**: at any moment we hold two breakpoints — one being "read" (from the previous turn) and one being "written" (at the current tail). Next turn, the old "write" becomes the new "read," and we write a fresh one at the new tail. There's never a moment where both buffers are invalid simultaneously.

#### Why exactly 2, not 3 or 4

Each additional marker costs a cache write at write-tier pricing. The only failure boundary we need to cover is the "old tail / new tail" edge, and two markers is exactly the minimum for that. A third marker lands further back in the prefix, writing a segment that will never be read independently. 2 covers the boundary. 3 is redundant.

#### Surviving tool call retries

This is the second benefit, and the actual motivation behind commit `7734c97`. When the model retries a tool call (error, Ctrl-C, broken stream), the last message gets discarded. With a single marker, that's an immediate cache miss. With double markers, the second-to-last marker usually survives, so single-step rollback still hits cache. Three markers would survive two-step rollbacks, but the cost doesn't justify the edge case.

#### Messages that must never be marked

Our marker selection logic has one hard rule: skip any message tagged `system_injected: true`. These are ephemeral messages (session context blocks, compression instructions) that won't exist in the same form next turn. A marker on them is a write that will never be read back. The selector walks backward from the tail, skips `system_injected` messages, and stops when it has two real conversation messages.

---

### Decision 2: Dynamic Session State Breaks System Prompts → Frozen System Prompt

Engineering discipline: our agent's system prompt is built once at session start, then byte-frozen. Any requirement to put dynamic information in the system prompt gets redirected elsewhere.

This is the foundation of the entire cache strategy. If the system prompt changes, every subsequent cache entry is invalidated. There is no partial fix.

But at least four kinds of information naturally "want" to live in the system prompt:

1. **Current date, working directory, OS** — the model needs these for correct commands.
2. **Current model ID** — helpful for self-adaptive behavior.
3. **Newly installed skills** — the model needs to see skill names to invoke them.
4. **Updated user preferences** (USER.md / SOUL.md) — the agent's personality and user context.

All four can change mid-session. If any of them is in the system prompt, a single change invalidates everything.

#### The [session context] block

Instead of the system prompt, we inject this information as a regular `user` message in the conversation history:

```
[Session context: Today is 2026-05-13, Tuesday. Current model: claude-sonnet-4-6.
OS: macOS. Working directory: /Users/.../project]
```

This message is tagged `system_injected: true`. It won't be selected by cache markers (Decision 1), won't count as a real user turn, and gets discarded during compression. Injection is date-gated: one per day, plus one on model switch. Most sessions see exactly one.

#### A bug that took a day to find

Our first implementation of `inject_session_context` was eager. It fired during agent construction, before the system prompt was built. This meant `@history.empty?` returned `false`, so `run()` skipped system prompt construction entirely. The agent sent its first request with a "today is Tuesday" message but no system prompt. Behavior was subtly broken for a day before we traced it.

The fix was one line: inject after the system prompt is built. The code comment that survived:

```ruby
# IMPORTANT: Skip injection when the system prompt hasn't been built yet.
# Otherwise, appending a user message to an empty history makes
# @history.empty? false, which causes run() to skip building the
# system prompt entirely.
```

Assembly order matters more than content. You can spend weeks designing each piece of the prefix, but if the assembly sequence is wrong by one step, the entire cache strategy is void.

#### How skill discovery works without touching the system prompt

Skills are rendered into the system prompt at session start, then frozen. A skill installed mid-session won't appear until the next session. We accept this friction. Re-rendering the system prompt on every skill install would invalidate the cache for all users on all sessions on every turn. Skill installation is low-frequency; cache hits are per-turn. The tradeoff is clear.

That said, `invoke_skill` reads each SKILL.md at call time, not at session start. So if a user explicitly asks for a newly installed skill, the system can still find and execute it, though it won't auto-discover it from the skill listing.

---

### Decision 3: Skills and Sub-Agents Bloat History → One Meta-Tool

`invoke_skill` is one of our 16 tools and does more work than any other. It provides skill hot-loading, sub-agent architecture, memory recall, and skill self-evolution, all in under 200 tokens of system prompt.

It spawns a sub-agent with its own conversation history but the same 16 tools. When the sub-agent finishes, the main agent only sees `invoke_skill → result`. All intermediate steps stay in the sub-agent's isolated session.

This matters for caching: a code review skill might read dozens of files and produce a long analysis. Without isolation, all that intermediate work would inflate the main agent's history, triggering compression earlier and costing more. With `invoke_skill`, the main agent's history stays clean.

And for extensibility: need a new capability? Drop a SKILL.md in `~/.clacky/skills/`. The `invoke_skill` tool is always present in the schema; it doesn't need to know about specific skills at compile time. The SKILL.md is read at invocation time. This one tool replaces what would otherwise be ~20 specialized tools, each bloating the schema and increasing the cache invalidation surface.

---

### Decision 4: Tool Growth Destabilizes Schema → Exactly 16 Tools

Tool schemas sit right after the system prompt in the cache prefix. If the schema changes, everything after it is invalidated. Every additional tool isn't just extra schema tokens; it's extra risk surface for cache invalidation the next time you change any tool.

But too few tools also cost money. If the model has to take three steps for something that one well-designed tool could handle in one step, you're paying for extra turns.

Our answer after months of iteration: 16 tools. File I/O (3), search (2), execution (1), browser (1), web (2), task management (4), interaction (1), extension (1), safety (1).

The design principles are simple: minimize parameters per tool (fewer ways for the model to get it wrong), no overlap between tools, and heavy RSpec coverage on every tool. A tool bug cascades: wrong observation → wrong decision → wasted retries.

If we ever need a 17th tool, we'll add it. Four months in, we haven't. The capabilities that didn't become tools became skills instead: code analysis, memory, scheduling, sub-agent orchestration. Each routed through `invoke_skill`, invisible to the tool schema.

---

### Decision 5: Long Sessions Exceed Context Limits → Insert-Then-Compress

Context windows are finite. Long tasks will fill them. Compression is the single biggest threat to cache hit rates: replacing old messages with a summary changes the prefix, guaranteeing a cache miss. So the question is how to minimize the damage.

#### Don't use a separate model for compression

Many agents compress by spawning an independent LLM call with a cheap/fast model and a "you are a summarization assistant" system prompt.

The problems:

- The compression call's system prompt doesn't match the main session. It has zero shared prefix with the main cache, so it's a 100% miss on the compression call itself.
- After compression, the main session's history has changed (old messages replaced by summary), so the main session's cache is also invalidated. You're running cold for the next 4-5 turns.

You pay twice for every compression event: once for the compression call's miss, and once for the main session's cold-to-warm recovery.

Our approach: **Insert-then-Compress.** Instead of a separate call, we insert the compression instruction as a `system_injected` message at the end of the current conversation, then send a normal request.

The effect:

- The compression call hits the existing cache. Same system prompt, same tools, same history prefix. Only the tail instruction (~500 tokens) is cold.
- After compression, we rebuild history as `[system_prompt, summary, last_N_messages]`. This does miss once, but only once. From the second turn onward, double markers take over again.

| | Separate model | Insert-then-Compress |
|---|---|---|
| Compression call cache hit | 0% | **~95%** |
| Cold tokens during compression | ~50,000 | **~500** |
| Main session cold turns after | 4–5 | **1** |

*Comparison for a 50K-token session compression event.*

#### The sweet spot: 200K–300K tokens

We tested multiple thresholds. 200K–300K tokens is where quality and cost balance. The model still effectively uses the context, with enough headroom to complete compression itself. After compression, history is always reduced to under 10K tokens, controlling the baseline cost of every subsequent turn.

#### Compress at idle, not at the next message

LLM providers expire prompt caches after ~5 minutes of inactivity. Once expired, the next turn is fully cold: 10× the cached price.

We run an idle timer (`idle_compression_timer.rb`): when the user stops typing for 90 seconds and history is approaching the threshold, we compress immediately, while the cache is still warm. The new short history establishes a fresh cache breakpoint before TTL expiry.

When the user comes back after a few minutes of thinking, the session is already compressed and warm. Without this, they'd face a cache-expired 300K-token history at full price. This single behavior saves roughly 10× on long-pause sessions.

#### The million-token context trap

"Million-token context" sounds impressive, but the model re-reads the entire context every turn. 1M tokens of input, even at 100% cache hit (0.1× price), costs the equivalent of 100K full-price tokens per turn. One cache miss and you pay for 1M tokens at full rate. Add the well-documented attention degradation in ultra-long contexts, and the math is clear.

Our strategy is the opposite of "fill up the context window": compress aggressively, keep history short. 10K tokens of compressed history at 95% cache hit is cheaper and more effective than 1M tokens of raw history at 99% cache hit.

---

### Decision 6: File Parsing Wants More Tools → Self-Maintained Scripts

PDF, Excel, Word, and PowerPoint parsing are common agent needs. Built-in tools would bloat the schema (violates Decision 4) and require C extensions (breaks zero-dependency install). Requiring users to install skills first is bad UX.

Our third path: on first install, copy a set of Python parsing scripts to `~/.clacky/scripts/`, then let the agent maintain them.

When the agent needs to read a PDF, it runs `python3 ~/.clacky/scripts/read_pdf.py <file>` via the `terminal` tool. The tool list doesn't grow. If a script fails (missing dependency, format edge case), the agent can fix the script and `pip install` whatever's needed. The capability isn't hard-coded in the gem. It lives in user-space scripts that the agent itself maintains and improves over time.

Why Python for scripts when the agent is Ruby? Pragmatism. Python's document processing ecosystem (`pdfplumber`, `openpyxl`, `python-docx`) is the most mature. We use the best tool for each layer.

---

### Decision 7: Browser Automation Wants Many MCP Tools → One Stable Browser Tool

Browser automation matters for agents, but the mainstream approaches have problems. Headless browsers (Puppeteer/Playwright) are invisible to the user, frequently blocked by anti-bot detection, and can't access existing login sessions. External MCP services require separate installation and may expose dozens of fine-grained tools that bloat the schema.

We take over the user's actual Chrome/Edge instead. The user enables Remote Debugging once (guided by a setup skill), and our built-in MCP client connects via stdio JSON-RPC. The agent operates on the browser the user can see — same cookies, same login sessions, same page state. When the agent clicks a button, the user watches it happen.

To the model, `browser` is one tool out of 16 with a stable schema. The complexity of daemon lifecycle management (startup, heartbeat, crash recovery) lives in `browser_manager.rb`, invisible to the cache layer.

This comes with obvious safety concerns. We keep the browser visible at all times, require explicit user-initiated setup, and treat browser automation as a high-trust local capability rather than a background cloud service. It is powerful precisely because it runs in the user's real session, so it should be used with the same caution as giving an assistant access to your logged-in browser.

---

## Why Ruby? (Yes, Really)

If you've read this far you might have noticed: this entire agent is written in Ruby. Not Python. Not TypeScript. Ruby.

On GitHub, there are about 4,700 repositories tagged "ai-agent" in Python, 2,800 in TypeScript, and **5 in Ruby.** Ruby is almost absent from the current AI agent ecosystem, which made this choice worth explaining.

We didn't choose Ruby to be contrarian. We chose it because the things an agent harness actually does — orchestrating API calls, managing cache boundaries, dynamically loading skills, maintaining tool registries — are things Ruby happens to be very good at.

Metaprogramming is a genuine advantage here. `method_missing`, `define_method`, `class_eval` — when your agent modifies its own helper scripts at runtime, when skills load dynamically without restart, when tool registration happens through introspection rather than config files, Ruby's metaprogramming pays real dividends.

Distribution is frictionless. `gem install openclacky` — done. Version management, dependency resolution, executable registration (`clacky` command), all out of the box. No virtual environments, no `node_modules`, no build step.

**Zero C extension dependencies.** This took significant engineering effort. Look at our gemspec:

```
faraday, thor, tty-prompt, tty-spinner, diffy, pastel,
tty-screen, tty-markdown, base64, logger, websocket,
webrick, artii, rubyzip, rouge, chunky_png
```

Every dependency is pure Ruby. No `brew install libxml2`, no `apt-get install libffi-dev`, no Xcode Command Line Tools.

To achieve this, we made unusual choices: pure-Ruby `websocket` gem instead of `websocket-driver` (which needs a C extension for UTF-8 validation); LLM streaming and tool_use protocol handling from scratch with raw `faraday` HTTP — because we needed direct control over `cache_control` field injection for Decision 1; terminal UI built with ANSI escape codes instead of `curses`.

These "build from scratch" decisions would have been impractical a few years ago. But the agent is itself an AI coding agent — we used it to write itself. A bootstrapping loop: the product made itself better.

---

## A Small Sanity Check, Not a Benchmark

A note on methodology: **this is not a rigorous benchmark.** We ran three real tasks (a slide deck, a marketing strategy, a social content pipeline) through four agents (ours, Claude Code, OpenClaw, Hermes) under controlled conditions — same prompt, same underlying model (claude-opus-4-7), same skills, same time window. All cost data comes from OpenRouter's per-request CSV billing, not estimates. Single run per agent, no cherry-picking.

We did this to get a feel for where we stand, not to make definitive claims. Take the numbers as directional.

| Agent | Cost | Requests | Cache Hit Rate |
|---|---|---|---|
| **Ours** | $5.10 | 51 | 90.6% |
| Claude Code | $5.49 | 70 | 95.2% |
| OpenClaw | $15.70 | 81 | 88.7% |
| Hermes | $30.14 | 218 | 60.3% |

*Total cost across 3 tasks. Data from OpenRouter per-request CSV billing.*

The cost difference isn't about unit price; prompt token pricing is roughly the same across agents using the same model. The difference is fewer requests × higher cache hit rate. 51 requests at 90.6% cache hit versus 218 requests at 60.3% cache hit — that's where the 6× gap comes from.

Claude Code's cache hit rate is actually higher than ours (95.2% vs 90.6%). They achieve this partly by having fewer features that conflict with caching. Our agent supports skills, sub-agents, browser automation, dynamic model switching, and idle compression — all things that structurally threaten cache coherence. Getting to 90.6% while supporting all of that is the engineering challenge this post describes.

Full results, per-task breakdowns, and the actual deliverables from each agent are at [openclacky.com/benchmark](https://www.openclacky.com/benchmark).

---

## Reproducibility

Everything needed to verify or re-run this comparison is public:

- **Runner script** — [`benchmark/runner.rb`](https://github.com/clacky-ai/openclacky/blob/main/benchmark/runner.rb)
- **OpenRouter CSV billing data** — [`benchmark/results/`](https://github.com/clacky-ai/openclacky/tree/main/benchmark/results) (per-request cost, cache hit/miss, token counts)
- **Task prompts and fixtures** — [`benchmark/fixtures/`](https://github.com/clacky-ai/openclacky/tree/main/benchmark/fixtures)
- **Evaluation report** — [`benchmark/results/EVALUATION_REPORT.md`](https://github.com/clacky-ai/openclacky/blob/main/benchmark/results/EVALUATION_REPORT.md)

We did not cherry-pick runs, post-process outputs, or re-run until numbers looked good. One run per agent, published as-is. This still does not make it a benchmark; it just makes the sanity check auditable. If you find errors in the data, open an issue.

---

## What We Actually Believe

These seven decisions share one conviction: spend your engineering budget on the harness, save your intelligence budget for the model.

We ripped out RAG because the model can read files directly. We killed multi-agent workflows because one main agent with good context management was faster, cheaper, and easier to debug. We still use sub-agents, but only behind invoke_skill, where they act as isolated execution sandboxes rather than peer collaborators. We kept the tool list small because the capabilities that didn't earn their place as tools became skills instead, routed through a single meta-tool.

These aren't universal truths. If you need real-time retrieval from a billion documents, or you're coordinating physical robots, your tradeoffs will differ. But for agents that help individual humans with coding and writing and automation, we think single-agent-with-great-caching has a lot of room to run.

Models get better fast. The things that *won't* be obsoleted by better models are the things we've invested in: cache geometry, tool stability, compression strategy, install experience. Harness-layer infrastructure that stays useful regardless of which model you plug in.

---

OpenClacky is fully open-source under the MIT license. The code behind every decision in this post:

- Cache marker logic — [`lib/clacky/client.rb`](https://github.com/clacky-ai/openclacky/blob/main/lib/clacky/client.rb)
- Insert-then-Compress — [`lib/clacky/agent/message_compressor.rb`](https://github.com/clacky-ai/openclacky/blob/main/lib/clacky/agent/message_compressor.rb)
- Session context injection — [`lib/clacky/agent.rb`](https://github.com/clacky-ai/openclacky/blob/main/lib/clacky/agent.rb)
- Idle compression timer — [`lib/clacky/idle_compression_timer.rb`](https://github.com/clacky-ai/openclacky/blob/main/lib/clacky/idle_compression_timer.rb)
- Browser tool — [`lib/clacky/tools/browser.rb`](https://github.com/clacky-ai/openclacky/blob/main/lib/clacky/tools/browser.rb)

→ [github.com/clacky-ai/openclacky](https://github.com/clacky-ai/openclacky)
