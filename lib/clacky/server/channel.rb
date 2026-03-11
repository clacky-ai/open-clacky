# frozen_string_literal: true

# Channel layer — bridges Server Sessions to IM platforms (Feishu, WeCom, etc.)
#
# Load order:
#   1. Adapter base & registry
#   2. Platform adapters (each self-registers via Adapters.register)
#   3. ChannelConfig (IM platform credentials)
#   4. ChannelUIController (UIInterface impl that sends to IM)
#   5. ChannelManager (orchestrates adapters + sessions, in-memory session map)
#
# Usage in HttpServer:
#   require_relative "channel"
#   @channel_manager = Clacky::Channel::ChannelManager.new(
#     session_registry: @registry,
#     session_builder:  method(:build_session),
#     channel_config:   Clacky::ChannelConfig.load
#   )
#   @channel_manager.start

require_relative "channel/adapters/base"

# Load platform adapters (each registers itself)
require_relative "channel/adapters/feishu/adapter"
require_relative "channel/adapters/wecom/adapter"

require_relative "channel/channel_config"
require_relative "channel/channel_ui_controller"
require_relative "channel/channel_manager"
