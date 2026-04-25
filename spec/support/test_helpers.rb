# frozen_string_literal: true

require "climate_control"

module TestHelpers
  # Capture stdout and stderr output
  def capture_output
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    begin
      yield
      $stdout.string + $stderr.string
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  # Create a temporary config file for testing
  def with_temp_config(config_data = {})
    Dir.mktmpdir do |dir|
      config_file = File.join(dir, "config.yml")
      File.write(config_file, config_data.to_yaml) unless config_data.empty?

      yield config_file
    end
  end

  # Modify environment variables for testing
  def with_env(env_vars)
    ClimateControl.modify(env_vars) { yield }
  end

  # Mock API response for testing
  def mock_api_response(content: "Test response", tool_calls: nil, finish_reason: nil, reasoning_content: nil)
    resp = {
      content: content,
      tool_calls: tool_calls,
      finish_reason: finish_reason || (tool_calls ? "tool_calls" : "stop"),
      usage: {
        prompt_tokens: 10,
        completion_tokens: 20,
        total_tokens: 30
      }
    }
    resp[:reasoning_content] = reasoning_content if reasoning_content
    resp
  end

  # Mock tool call for testing
  def mock_tool_call(name: "calculator", args: '{"expression":"1+1"}')
    {
      id: "call_#{SecureRandom.hex(4)}",
      type: "function",
      name: name,
      arguments: args
    }
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
