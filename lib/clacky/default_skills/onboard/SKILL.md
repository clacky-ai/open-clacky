---
name: onboard
description: Onboard a new user by collecting AI personality preferences and user profile, then writing SOUL.md and USER.md.
disable-model-invocation: true
user-invocable: true
---

# Skill: onboard

## Purpose
Guide a new user through personalizing their Clacky experience via interactive cards.
Collect AI personality preferences and user profile, then write `SOUL.md` and `USER.md`.
All structured input is gathered through `request_user_feedback` cards — no free-form interrogation.

## Steps

### 0. Detect language

The user's language was set during the onboarding intro screen. The skill is invoked with
a `lang:` argument in the slash command, e.g. `/onboard lang:zh` or `/onboard lang:en`.

Check the invocation message for `lang:zh` or `lang:en`:
- If `lang:zh` is present → conduct the **entire** onboard in **Chinese**, write SOUL.md & USER.md in Chinese.
- Otherwise (or if missing) → use **English** throughout.

If the `lang:` argument is absent, infer from the user's first reply; default to English.

### 1. Greet the user

Send a short, warm welcome message (2–3 sentences). Use the language determined in Step 0.
Do NOT ask any questions yet.

Example (English):
> Hi! I'm your personal assistant ⚡
> Let's take 30 seconds to personalize your experience — I'll ask just a couple of quick things.

Example (Chinese):
> 嗨！我是你的专属 AI 助手 ⚡
> 只需 30 秒完成个性化设置，我会问你两个简单问题。

### 2. Ask the user to name the AI (card)

Call `request_user_feedback` to let the user pick or type a name for their AI assistant.
Offer a few fun suggestions as options, plus a free-text fallback.

If `lang == "zh"`, use:
```json
{
  "question": "先来点有意思的 —— 你想叫我什么名字？可以选一个，也可以直接输入你喜欢的：",
  "options": ["🐟 摸鱼王", "📚 卷王", "🌟 小天才", "🐱 本喵", "🌅 拾光", "自己输入名字…"]
}
```

Otherwise (English):
```json
{
  "question": "Let's start with something fun — what would you like to call me? Pick one or type your own:",
  "options": ["✨ Aria", "🤖 Max", "🌙 Luna", "⚡ Zap", "🎯 Ace", "Type your own name…"]
}
```

If the user selects the last option or types a custom name, use that as-is. If they chose from the list, strip any emoji prefix.
Store the result as `ai.name` (default `"Clacky"` if blank).

### 3. Collect AI personality (card)

Call `request_user_feedback` with a card to set the assistant's personality.
Address the AI by `ai.name` in the question.

If `lang == "zh"`, use:
```json
{
  "question": "好的！[ai.name] 应该是什么风格呢？",
  "options": [
    "🎯 专业型 — 精准、结构化、不废话",
    "😊 友好型 — 热情、鼓励、像一位博学的朋友",
    "🎨 创意型 — 富有想象力，善用比喻，充满热情",
    "⚡ 简洁型 — 极度简短，用要点，信噪比最高"
  ]
}
```

Otherwise (English):
```json
{
  "question": "Great! What personality should [ai.name] have?",
  "options": [
    "🎯 Professional — Precise, structured, minimal filler",
    "😊 Friendly — Warm, encouraging, like a knowledgeable friend",
    "🎨 Creative — Imaginative, uses metaphors, enthusiastic",
    "⚡ Concise — Ultra-brief, bullet points, maximum signal"
  ]
}
```

Map the chosen option to a personality key:
- Option 1 → `professional`
- Option 2 → `friendly`
- Option 3 → `creative`
- Option 4 → `concise`

Store: `ai.personality`.

### 4. Collect user profile (card)

Call `request_user_feedback` again. This is where we learn about the user themselves.

If `lang == "zh"`, use:
```json
{
  "question": "那你呢？随便聊聊自己吧 —— 全部可选，填多少都行：\n• 你的名字（我该怎么称呼你？）\n• 职业\n• 最希望用 AI 做什么\n• 社交 / 作品链接（GitHub、微博、个人网站等）—— 我会读取公开信息来更了解你",
  "options": []
}
```

Otherwise (English):
```json
{
  "question": "Now a bit about you — all optional, skip anything you like.\n• Your name (what should I call you?)\n• Occupation\n• What you want to use AI for most\n• Social / portfolio links (GitHub, Twitter/X, personal site…) — I'll read them to learn about you",
  "options": []
}
```

Parse the user's reply as free text; extract whatever they provide.
Store the user's name as `user.name` (default `"老大"` for Chinese, `"Boss"` for English if blank).

### 5. Learn from links (if any)

For each URL the user provided, use the `web_search` tool or fetch the page to read
publicly available info: bio, projects, tech stack, interests, writing style, etc.
Note key facts for the USER.md. Skip silently if a URL is unreachable.

### 6. Write SOUL.md

Write to `~/.clacky/agents/SOUL.md`.

Use `ai.name` and `ai.personality` to shape the content.
Write in the language determined in Step 0 (`zh` → Chinese, otherwise English).
If `lang == "zh"`, add a line: `**始终用中文回复用户。**` near the top of the Identity section.

**Personality style guide:**

| Key | Tone |
|-----|------|
| `professional` | Concise, precise, structured. Gets to the point. Minimal filler. |
| `friendly` | Warm, uses light humor, feels like a knowledgeable friend. |
| `creative` | Imaginative, uses metaphors, thinks outside the box, enthusiastic. |
| `concise` | Ultra-brief. Bullet points. Maximum signal-to-noise ratio. |

Template:

```markdown
# [AI Name] — Soul

## Identity
I am [AI Name], a personal assistant and technical co-founder.
[1–2 sentences reflecting the chosen personality.]

## Personality & Tone
[3–5 bullet points describing communication style.]

## Core Strengths
- Translating ideas into working code quickly
- Breaking down complex problems into clear steps
- Spotting issues before they become problems
- Adapting explanation depth to the user's background

## Working Style
[2–3 sentences about how I approach tasks, matching the personality.]
```

### 7. Write USER.md

Write to `~/.clacky/agents/USER.md`.

```markdown
# User Profile

## About
- **Name**: [user.name, or "Not provided"]
- **Occupation**: [or "Not provided"]
- **Primary Goal**: [or "Not provided"]

## Background & Interests
[If links were fetched: 3–5 bullet points from what was learned.
 Otherwise: omit section or write "No additional context."]

## How to Help Best
[1–2 sentences tailored to the user's goal and background.]
```

### 7b. Write USER.md (Chinese version, if applicable)

If `lang == "zh"`, write `~/.clacky/agents/USER.md` in Chinese:

```markdown
# 用户档案

## 基本信息
- **姓名**: [user.name，未填则写「未填写」]
- **职业**: [未填则写「未填写」]
- **主要目标**: [未填则写「未填写」]

## 背景与兴趣
[如有链接：3–5 条从公开信息中提取的要点。否则：写「暂无更多背景信息。」]

## 如何最好地帮助用户
[1–2 句话，根据用户目标和背景量身定制。]
```

### 8. Confirm and close

If `lang == "zh"`, reply:
> 全部设置完成！我已保存你的偏好。关掉这个对话，开启一个新对话就可以开始了 —— 尽情享用吧！🚀

Otherwise:
> All set! I've saved your preferences. Feel free to close this tab and start a fresh session — enjoy! 🚀

Do NOT open a new session — the UI handles navigation after the skill finishes.

## Notes
- Keep both files under 300 words each.
- Do not ask follow-up questions beyond the two cards above.
- Work with whatever the user provides; fill in sensible defaults for anything omitted.
