# Channel Architecture

## Overview

Channel is a feature that bridges Clacky's Server Sessions to IM platforms
(Feishu, WeCom, DingTalk, etc.). It reuses the existing Agent + SessionRegistry
infrastructure — the Agent knows nothing about IM; the Channel layer is purely
a transport adapter.

## Design Principles

- **Zero Agent intrusion** — Agent only speaks `UIInterface`; swap the controller, get IM output
- **Reuse SessionRegistry** — IM chats resolve to the same `SessionRegistry` sessions as Web UI
- **WebSocket long connection** — No public domain required; adapters hold a persistent WSS connection to the IM platform
- **One platform = 2 threads** — read loop thread + ping/heartbeat thread (constant, small footprint)

---

## Layer Diagram

```
IM Platforms (Feishu / WeCom / DingTalk)
      │  WebSocket long connection (wss://)
      ▼
┌─────────────────────────────────────┐
│       Channel Adapter Layer         │
│  Feishu::Adapter                    │
│    ├── WSClient   (read loop + ping) │
│    ├── Bot        (send API)         │
│    └── MessageParser                │
│  Wecom::Adapter                     │
│    └── WSClient   (read loop + ping) │
│  (future) Dingtalk::Adapter         │
└──────────────┬──────────────────────┘
               │ standardized event Hash
               ▼
┌─────────────────────────────────────┐
│          ChannelManager             │
│  • Owns adapter threads             │
│  • Routes inbound event →           │
│    ChannelBinding → session_id      │
│  • Calls agent.run in Thread.new    │
└──────────────┬──────────────────────┘
               │
       ┌───────┴────────┐
       ▼                ▼
SessionRegistry    ChannelUIController
(existing)         (implements UIInterface)
       │                │
       ▼                ▼
    Agent            IM Platform reply
  (unchanged)       via adapter.send_text
```

---

## File Structure

```
lib/clacky/channel/
├── adapters/
│   ├── base.rb                  # Adapter abstract base + registry
│   ├── feishu/
│   │   ├── adapter.rb           # Feishu::Adapter < Base
│   │   ├── bot.rb               # HTTP send API (token cache, Markdown/card)
│   │   ├── message_parser.rb    # Raw WS event → standardized Hash
│   │   └── ws_client.rb         # Feishu protobuf WS long connection
│   └── wecom/
│       ├── adapter.rb           # Wecom::Adapter < Base
│       └── ws_client.rb         # WeCom JSON WS long connection
├── channel_message.rb           # Struct: standardized inbound message
├── channel_binding.rb           # (platform, user_id) → session_id mapping
├── channel_ui_controller.rb     # UIInterface impl — pushes events to IM
└── channel_manager.rb           # Lifecycle: start/stop adapters, route messages
lib/clacky/channel.rb            # Top-level require entry point
```

---

## Standardized Inbound Event

All adapters yield the same Hash shape to `ChannelManager`:

```ruby
{
  platform:   :feishu,          # Symbol
  chat_id:    "oc_xxx",         # String — IM chat/group identifier
  user_id:    "ou_xxx",         # String — IM user identifier
  text:       "deploy now",     # String — cleaned user text
  message_id: "om_xxx",         # String — for threading / update
  timestamp:  Time,             # Time object
  chat_type:  :direct | :group, # Symbol
  raw:        { ... }           # Original platform payload
}
```

---

## Adapter Interface (Base)

```ruby
class Adapters::Base
  def self.platform_id → Symbol
  def self.platform_config(raw_config) → Hash   # symbol-keyed
  def self.env_keys → Array<String>             # for config serialization

  def start(&on_message)   # blocks; yields event Hash per inbound message
  def stop                 # graceful shutdown
  def send_text(chat_id, text, reply_to: nil) → Hash
  def update_message(chat_id, message_id, text) → Boolean
  def supports_message_updates? → Boolean
  def validate_config(config) → Array<String>   # error messages
end
```

---

## ChannelManager

```ruby
class ChannelManager
  def initialize(session_registry:, session_builder:, channel_config:, agent_config:)

  def start   # Thread.new per enabled platform adapter
  def stop    # kills all adapter threads gracefully

  private

  def route_message(adapter, event)
    session_id = @binding.resolve_or_create(event, session_builder: @session_builder)
    ui         = ChannelUIController.new(event, adapter)
    Thread.new { run_agent(session_id, event[:text], ui) }
  end
end
```

---

## ChannelBinding

Maps `(platform, user_id)` → `session_id`. Persisted to `~/.clacky/channel_bindings.yml`.

Binding modes (configurable per platform):

| Mode | Key | Description |
|------|-----|-------------|
| `user` | `(platform, user_id)` | Each IM user gets their own session (default) |
| `chat` | `(platform, chat_id)` | Whole group shares one session |

---

## ChannelUIController

Implements `UIInterface`. Key behaviours:

- `show_assistant_message` → `adapter.send_text(chat_id, content)`
- `show_tool_call` → buffers as `⚙️ \`tool summary\`` (flushed on next message)
- `show_progress` → `adapter.update_message(...)` if `supports_message_updates?`
- `show_complete` → sends `✅ Complete • N iterations • $cost`
- `request_confirmation` → **not supported in IM** (returns auto-approved / raises)

---

## Thread Model

```
Main thread  (WEBrick server.start — blocks)
├── WEBrick request threads    (existing)
├── Agent task threads         (existing, per task)
├── Scheduler thread           (existing, clacky-scheduler)
└── ChannelManager
    ├── feishu-adapter thread  (WSClient read loop, constant)
    │   └── feishu-ping thread (heartbeat, 90s)
    └── wecom-adapter thread   (WSClient read loop, constant)
        └── wecom-ping thread  (heartbeat, 30s)
```

Per enabled platform: **2 constant threads**. Agent task threads are spawned
on demand (same as Web UI path) and exit when done.

---

## Configuration

Channel credentials live in `~/.clacky/channels.yml` (managed by `ChannelConfig`
which already exists in main branch):

```yaml
channels:
  feishu:
    enabled: true
    app_id: cli_xxx
    app_secret: xxx
    allowed_users:
      - ou_xxx
  wecom:
    enabled: false
    bot_id: xxx
    secret: xxx
```

`ChannelManager` reads this via `ChannelConfig#platform_config(platform)`.

---

## Integration with HttpServer

```ruby
# HttpServer#initialize
@channel_manager = ChannelManager.new(
  session_registry: @registry,
  session_builder:  method(:build_session),
  channel_config:   Clacky::ChannelConfig.load,
  agent_config:     @agent_config
)

# HttpServer#start  (after scheduler.start)
@channel_manager.start
```

`ChannelManager#start` is non-blocking (spawns threads internally),
mirroring `Scheduler#start` behaviour.

---

## Future: DingTalk

DingTalk also supports a WebSocket Stream mode. Adding it means:

1. `lib/clacky/channel/adapters/dingtalk/adapter.rb` inheriting `Base`
2. `lib/clacky/channel/adapters/dingtalk/ws_client.rb`
3. Register: `Adapters.register(:dingtalk, Adapter)`
4. Add credentials to `ChannelConfig`

No changes needed to `ChannelManager`, `ChannelUIController`, or `ChannelBinding`.
