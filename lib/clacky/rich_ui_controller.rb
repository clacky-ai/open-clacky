# frozen_string_literal: true

require "json"
require_relative "ui_interface"
require_relative "providers"
require_relative "ui2/components/welcome_banner"

begin
  require "ruby_rich"
rescue LoadError
  require_relative "../../../ruby_rich/lib/ruby_rich"
end

module RubyRich
  class Transcript
    unless private_method_defined?(:clacky_render_entry_without_plain)
      alias_method :clacky_render_entry_without_plain, :render_entry

      def render_entry(entry, index)
        if entry.metadata[:plain]
          entry.content.to_s.split("\n", -1)
        else
          clacky_render_entry_without_plain(entry, index)
        end
      end

      private :render_entry
    end
  end

  class Markdown
    class TerminalRenderer
      unless method_defined?(:clacky_fit_table_rows)
        def table(header, body)
          all_rows = @table_state[:all_rows]
          reset_table_state
          return "" if all_rows.empty?

          header_line_count = [header.to_s.strip.split("\n").size, 1].max
          header_rows = all_rows[0...header_line_count]
          body_rows = all_rows[header_line_count..] || []

          return "" if header_rows.empty? || body_rows.empty?

          headers, fitted_body_rows = clacky_fit_table_rows(header_rows.last, body_rows)
          begin
            tbl = RubyRich::Table.new(headers: headers, border_style: @options[:table_border_style] || :simple)
            fitted_body_rows.each do |row|
              padded = row + Array.new([0, headers.length - row.length].max, "")
              tbl.add_row(padded[0...headers.length])
            end
            return "#{tbl.render}\n\n"
          rescue
            # fall through to the original plain fallback shape
          end

          result = "\n"
          result += "#{header.strip}\n"
          result += "#{"-" * [header.strip.length, 20].min}\n"
          result += "#{body.strip}\n" if body && !body.strip.empty?
          "#{result}\n"
        end

        def clacky_fit_table_rows(header_row, body_rows)
          column_count = [header_row.length, *body_rows.map(&:length)].max.to_i
          normalized_header = header_row + Array.new([0, column_count - header_row.length].max, "")
          normalized_body = body_rows.map { |row| row + Array.new([0, column_count - row.length].max, "") }
          natural_widths = clacky_table_natural_widths(normalized_header, normalized_body)
          column_widths = clacky_constrain_table_widths(natural_widths)

          headers = normalized_header.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          rows = normalized_body.map do |row|
            row.each_with_index.map { |cell, index| clacky_wrap_table_cell(clacky_table_cell_text(cell), column_widths[index]) }
          end

          [headers, rows]
        end

        def clacky_table_natural_widths(header_row, body_rows)
          rows = [header_row] + body_rows
          rows.transpose.map do |cells|
            cells.map { |cell| clacky_visible_width(clacky_table_cell_text(cell)) }.max.to_i
          end
        end

        def clacky_table_cell_text(cell)
          process_inline(cell).to_s.gsub(/\e\[[0-9;:]*m/, "")
        end

        def clacky_constrain_table_widths(natural_widths)
          return natural_widths if natural_widths.empty?

          border_overhead = (natural_widths.length * 3) + 1
          max_table_width = [[@options[:width].to_i - 1, 20].max, border_overhead + natural_widths.length].max
          available_content_width = [max_table_width - border_overhead, natural_widths.length].max
          widths = natural_widths.map { |width| [width, 1].max }
          return widths if widths.sum <= available_content_width

          min_width = available_content_width < natural_widths.length * 3 ? 1 : 3
          while widths.sum > available_content_width
            index = widths.each_with_index.select { |width, _| width > min_width }.max_by(&:first)&.last
            break unless index

            widths[index] -= 1
          end
          widths
        end

        def clacky_wrap_table_cell(text, width)
          width = [width.to_i, 1].max
          text.to_s.split("\n", -1).flat_map do |line|
            clacky_wrap_table_line(line, width)
          end.join("\n")
        end

        def clacky_wrap_table_line(line, width)
          return [""] if line.empty?

          lines = []
          current = +""
          current_width = 0
          in_escape = false
          escape = +""

          line.each_char do |char|
            if in_escape
              escape << char
              if char == "m"
                current << escape
                escape = +""
                in_escape = false
              end
              next
            elsif char.ord == 27
              escape << char
              in_escape = true
              next
            end

            char_width = Unicode::DisplayWidth.of(char)
            if current_width.positive? && current_width + char_width > width
              lines << current
              current = +""
              current_width = 0
            end
            current << char
            current_width += char_width
          end

          lines << current unless current.empty?
          lines.empty? ? [""] : lines
        end

        def clacky_visible_width(text)
          text.to_s.gsub(/\e\[[0-9;:]*m/, "").split("\n").map(&:display_width).max.to_i
        end
      end
    end
  end
end

module Clacky
  class RichAgentShell < RubyRich::AgentShell
    private

    def build_layout
      root = RubyRich::Layout.new(name: :root)
      root.split_column(
        RubyRich::Layout.new(name: :header, size: 1),
        RubyRich::Layout.new(name: :body, ratio: 1),
        RubyRich::Layout.new(name: :composer, size: 6),
        RubyRich::Layout.new(name: :status, size: 1)
      )

      root[:body].split_row(
        RubyRich::Layout.new(name: :transcript, ratio: 1)
      )

      root[:header].content = RubyRich::AppShell::HeaderView.new(self)
      root[:transcript].content = @viewport
      root[:composer].content = RubyRich::AppShell::FramedView.new(@composer, title: "Composer", theme: @theme) { @composer.focused? }
      root[:status].content = RubyRich::AppShell::StatusView.new(self)
      root
    end

    def attach_components
      @viewport.attach(@layout[:transcript])
      @transcript.attach(@layout[:transcript])
      @composer.focus.attach(@layout[:composer])

      @focus_manager
        .register(:transcript, @layout[:transcript], RubyRich::AppShell::FocusTarget.new(@transcript, @viewport))
        .register(:composer, @layout[:composer], @composer)
        .attach(@layout)
      @focus_manager.focus(:composer)

      @layout.key(:ctrl_c, 1_000) do |_event, live|
        live.stop if @stop_on_ctrl_c != false
        false
      end
    end
  end

  # Experimental RubyRich-backed TUI controller.
  #
  # This intentionally implements the same surface as UI2::UIController so the
  # CLI/Agent loop can switch implementations without knowing which TUI is
  # underneath. It is not the default UI yet.
  class RichUIController
    include Clacky::UIInterface

    COMMANDS = [
      { label: "/clear", value: "/clear", description: "Clear output and restart session" },
      { label: "/config", value: "/config", description: "Open configuration" },
      { label: "/undo", value: "/undo", description: "Restore a previous task state" },
      { label: "/help", value: "/help", description: "Show commands" },
      { label: "/exit", value: "/exit", description: "Exit application", aliases: ["/quit"] }
    ].freeze

    attr_reader :layout, :shell, :running
    attr_accessor :config

    def initialize(config = {})
      @config = {
        working_dir: config[:working_dir],
        mode: config[:mode],
        model: config[:model],
        theme: config[:theme]
      }
      @welcome_banner = Clacky::UI2::Components::WelcomeBanner.new
      @shell = RichAgentShell.new(
        title: "OpenClacky",
        subtitle: config[:working_dir].to_s,
        model: config[:model].to_s,
        commands: COMMANDS
      )
      @layout = LayoutAdapter.new(@shell)
      @input_callback = nil
      @interrupt_callback = nil
      @mode_toggle_callback = nil
      @time_machine_callback = nil
      @tasks_count = 0
      @total_cost = 0.0
      @running = false
      @tool_ids = []
      @legacy_progress = {}
      @stdout_lines = []
      @callback_threads = []

      wire_shell_callbacks
    end

    def initialize_and_show_banner(recent_user_messages: nil)
      @running = true
      @shell.update_status(session_status)
      if recent_user_messages && !recent_user_messages.empty?
        @shell.add_separator("recent session")
        recent_user_messages.each { |message| @shell.add_user_message(message) }
      else
        add_plain_block(render_welcome_banner)
      end
    end

    def start
      initialize_and_show_banner unless @running
      start_input_loop
    end

    def start_input_loop
      @running = true
      @shell.start
    ensure
      @running = false
    end

    def stop(clear_screen: false)
      @running = false
      @shell.stop
      RubyRich::Terminal.clear if clear_screen
    end

    def set_skill_loader(_skill_loader, _agent_profile = nil); end
    def set_agent(_agent, _agent_profile = nil); end

    def on_input(&block)
      @input_callback = block
    end

    def on_interrupt(&block)
      @interrupt_callback = block
    end

    def on_mode_toggle(&block)
      @mode_toggle_callback = block
    end

    def on_time_machine(&block)
      @time_machine_callback = block
    end

    def append_output(content)
      return if content.nil?

      @shell.add_markdown(content.to_s)
    end

    def log(message, level: :info)
      case level.to_sym
      when :error then show_error(message)
      when :warning, :warn then show_warning(message)
      when :debug then nil
      else show_info(message)
      end
    end

    def show_assistant_message(content, files:)
      text = filter_thinking_tags(content)
      add_conversation_markdown(text) unless text.nil? || text.strip.empty?
      add_file_summary(files)
    end

    def show_tool_call(name, args)
      id = @shell.start_tool_call(name: name.to_s, input: format_args(args), status: :running)
      @tool_ids << id if id
    end

    def show_tool_result(result)
      if (id = @tool_ids.pop)
        @shell.finish_tool_call(id, status: :done, output: result.to_s)
      else
        @shell.add_markdown(result.to_s)
      end
    end

    def show_tool_stdout(lines)
      @stdout_lines.concat(Array(lines).map(&:to_s))
    end

    def show_tool_error(error)
      message = error.is_a?(Exception) ? error.message : error.to_s
      if (id = @tool_ids.pop)
        @shell.finish_tool_call(id, status: :error, output: message)
      else
        @shell.add_error_message(message)
      end
    end

    def show_tool_args(formatted_args)
      append_output("Args: #{formatted_args}")
    end

    def show_file_write_preview(path, is_new_file:)
      append_output("#{is_new_file ? "Creating" : "Modifying"} file: #{path || "(unknown)"}")
    end

    def show_file_edit_preview(path)
      append_output("Editing file: #{path || "(unknown)"}")
    end

    def show_file_error(error_message)
      show_error(error_message)
    end

    def show_shell_preview(command)
      append_output("$ #{command}")
    end

    def show_diff(old_content, new_content, max_lines: 50)
      require "diffy"
      diff = Diffy::Diff.new(old_content, new_content, context: 3).to_s(:color)
      lines = diff.lines
      visible = lines.take(max_lines).join
      hidden = lines.length - max_lines
      visible += "\n... (#{hidden} more lines hidden)" if hidden.positive?
      @shell.add_diff(content: visible)
    rescue LoadError
      append_output("Old size: #{old_content.bytesize} bytes\nNew size: #{new_content.bytesize} bytes")
    end

    def show_token_usage(token_data)
      @shell.show_token_usage(
        input: token_data[:prompt_tokens],
        output: token_data[:completion_tokens],
        total: token_data[:total_tokens],
        cost: token_data[:cost]
      )
    end

    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil)
      set_idle_status
      return if awaiting_user_feedback || iterations <= 5

      parts = ["Completed #{iterations} iterations", "cost $#{cost.round(4)}"]
      parts << "#{duration.round(1)}s" if duration
      append_output(parts.join(" · "))
    end

    def show_info(message, prefix_newline: true)
      _ = prefix_newline
      @shell.add_system_message(message.to_s)
    end

    def show_warning(message)
      @shell.add_system_message("Warning: #{message}")
    end

    def show_error(message)
      @shell.add_error_message(message.to_s)
    end

    def show_success(message)
      @shell.add_system_message("OK: #{message}")
    end

    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {})
      _ = prefix_newline
      type = progress_type.to_s
      if phase.to_s == "done"
        @legacy_progress.delete(type)&.finish(final_message: message)
        return
      end

      handle = @legacy_progress[type]
      if handle
        handle.update(message: message, metadata: metadata)
      else
        @legacy_progress[type] = start_progress(message: message, style: type == "thinking" ? :primary : :quiet)
      end
    end

    def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      _ = quiet_on_fast_finish
      ProgressHandleAdapter.new(@shell.start_progress(message || "Working", style: style))
    end

    def with_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      handle = start_progress(message: message, style: style, quiet_on_fast_finish: quiet_on_fast_finish)
      begin
        yield handle
      ensure
        handle.finish
      end
    end

    def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil)
      _ = cost_source
      _ = latency
      @tasks_count = tasks if tasks
      @total_cost = cost if cost
      @status = status if status
      @shell.update_status(session_status)
    end

    def update_todos(todos)
      @shell.update_tasks(Array(todos).map { |todo| normalize_todo(todo) })
    end

    def set_working_status
      update_sessionbar(status: "working")
    end

    def set_idle_status
      update_sessionbar(status: "idle")
    end

    def request_confirmation(message, default: true)
      show_info(message)
      @shell.confirm(
        title: "Confirm",
        message: message,
        choices: [{ key: true, label: "Yes" }, { key: false, label: "No" }],
        default: default
      )
    end

    def clear_input
      @shell.composer.editor.clear
    end

    def set_input_tips(message, type: :info)
      update_sessionbar(status: "#{type}: #{message}")
    end

    def show_help
      @shell.add_markdown(<<~HELP)
        Commands:
          /clear - Clear output and restart session
          /exit - Exit application

        Input:
          Shift+Enter - New line
          Up/Down - History navigation
          Ctrl+C - Interrupt current task
      HELP
    end

    def show_config_modal(current_config, test_callback: nil)
      return nil unless @running

      loop do
        choices = config_menu_choices(current_config)
        result = show_menu_dialog(
          title: "Model Configuration",
          choices: choices,
          selected_index: config_initial_selection(choices)
        )
        return nil if result.nil?

        case result[:action]
        when :switch
          return result
        when :add
          new_model = show_model_edit_form(nil, test_callback: test_callback)
          if new_model
            anthropic_format = new_model[:provider] == "anthropic"
            current_config.add_model(
              model: new_model[:model],
              api_key: new_model[:api_key],
              base_url: new_model[:base_url],
              anthropic_format: anthropic_format
            )
            new_id = current_config.models.last["id"]
            return { action: :add, model_id: new_id }
          end
        when :edit
          current_model = current_config.current_model
          edited = show_model_edit_form(current_model, test_callback: test_callback)
          if edited
            current_model["api_key"] = edited[:api_key]
            current_model["model"] = edited[:model]
            current_model["base_url"] = edited[:base_url]
            return { action: :edit, model_id: current_model["id"] }
          end
        when :delete
          if current_config.models.length <= 1
            show_warning("Cannot delete the last model.")
            next
          end

          current_config.remove_model(current_config.current_model_index)
          new_current = current_config.current_model
          return { action: :delete, model_id: new_current && new_current["id"] }
        when :close
          return nil
        end
      end
    end

    def filter_thinking_tags(content)
      return content if content.nil?

      content.gsub(%r{<think(?:ing)?>[\s\S]*?</think(?:ing)?>}mi, "").gsub(/\n{3,}/, "\n\n").strip
    end

    private

    def add_conversation_markdown(text)
      @shell.add_markdown(normalize_markdown_for_terminal(text))
    end

    def add_plain_block(text)
      @shell.transcript.add_block(:markdown, expand_ansi_multiline_spans(text), metadata: { plain: true })
      @shell.viewport.scroll_to_bottom
    end

    def expand_ansi_multiline_spans(text)
      active = +""
      text.to_s.lines.map do |line|
        body = line.chomp
        prefix = body.start_with?("\e[") || active.empty? ? "" : active
        body.scan(/\e\[[0-9;:]*m/).each do |code|
          active = code == RubyRich::AnsiCode.reset ? +"" : code
        end
        suffix = !active.empty? && !body.end_with?(RubyRich::AnsiCode.reset) ? RubyRich::AnsiCode.reset : ""
        "#{prefix}#{body}#{suffix}"
      end.join("\n")
    end

    def normalize_markdown_for_terminal(text)
      text.to_s
        .gsub(/\r\n?/, "\n")
        .gsub(/\A[ \t]*\n+/, "")
        .gsub(/\n+[ \t]*\z/, "")
    end

    def add_file_summary(files)
      items = Array(files).filter_map do |file|
        path = file[:path] || file["path"] || file[:name] || file["name"]
        next if path.to_s.strip.empty?

        "- `#{path}`"
      end
      return if items.empty?

      @shell.add_markdown("**Files**\n\n#{items.join("\n")}")
    end

    def wire_shell_callbacks
      @shell.on_submit do |text, attachments|
        files = Array(attachments).map { |attachment| attachment.respond_to?(:to_h) ? attachment.to_h : attachment }
        @shell.add_user_message(text)
        run_callback_async { @input_callback&.call(text, files, display: text) }
      end

      @shell.on_interrupt do |input_was_empty:|
        @interrupt_callback&.call(input_was_empty: input_was_empty)
      end

      @shell.on_mode_toggle do |mode|
        @config[:mode] = mode.to_s
        @mode_toggle_callback&.call(mode.to_s)
      end
    end

    def session_status
      [
        @status || "idle",
        @config[:mode],
        @config[:model],
        "#{@tasks_count} tasks",
        "$#{@total_cost.round(4)}"
      ].compact.join(" · ")
    end

    def run_callback_async(&block)
      @callback_threads.reject! { |thread| !thread.alive? }
      @callback_threads << Thread.new do
        block.call
      rescue StandardError => e
        show_error(e.message)
      end
    end

    def render_welcome_banner
      @welcome_banner.render_full(
        working_dir: @config[:working_dir].to_s,
        mode: @config[:mode].to_s,
        width: terminal_width
      )
    end

    def terminal_width
      if defined?(TTY::Screen)
        TTY::Screen.width
      else
        120
      end
    rescue StandardError
      120
    end

    def config_menu_choices(current_config)
      choices = current_config.models.each_with_index.map do |model, index|
        type_badge = case model["type"]
                     when "default" then "[default] "
                     when "lite" then "[lite] "
                     else ""
                     end
        {
          label: "#{type_badge}#{model["model"] || "unnamed"} (#{mask_api_key(model["api_key"])})",
          value: { action: :switch, model_id: model["id"] },
          current: index == current_config.current_model_index
        }
      end

      choices + [
        { label: "─" * 50, disabled: true },
        { label: "[+] Add New Model", value: { action: :add } },
        { label: "[*] Edit Current Model", value: { action: :edit } },
        (current_config.models.length > 1 ? { label: "[-] Delete Model", value: { action: :delete } } : nil),
        { label: "[X] Close", value: { action: :close } }
      ].compact
    end

    def config_initial_selection(choices)
      choices.index { |choice| choice[:current] } || choices.index { |choice| !choice[:disabled] } || 0
    end

    def show_menu_dialog(title:, choices:, selected_index: nil)
      selected_index ||= config_initial_selection(choices)
      dialog = ConfigMenuDialog.new(title: title, choices: choices, selected_index: selected_index)

      dialog.key(:up, 1_000) { dialog.move_up; true }
      dialog.key(:down, 1_000) { dialog.move_down; true }
      dialog.key(:string, 1_000) do |event, _live|
        case event[:value]
        when "k" then dialog.move_up
        when "j" then dialog.move_down
        when "q" then dialog.finish(nil)
        end
        true
      end
      dialog.key(:enter, 1_000) do
        selected = dialog.selected_choice
        dialog.finish(selected && !selected[:disabled] ? selected[:value] : nil)
      end
      dialog.key(:escape, 1_000) { dialog.finish(nil) }

      show_blocking_dialog(dialog)
    end

    def show_form_dialog(title:, fields:)
      dialog = FormDialog.new(title: title, fields: fields)
      dialog.key(:escape, 1_000) { dialog.finish(nil) }
      show_blocking_dialog(dialog)
    end

    def show_blocking_dialog(dialog)
      @shell.layout.show_dialog(dialog)
      dialog.wait
    ensure
      @shell.layout.hide_dialog if @shell.layout.dialog.equal?(dialog)
    end

    def show_model_edit_form(model, test_callback: nil)
      is_new = model.nil?
      model ||= {}
      selected_provider = nil

      if is_new
        selected_provider = show_provider_selection
        return nil if selected_provider.nil?
      end

      provider_preset = selected_provider && selected_provider != "custom" ? Clacky::Providers.get(selected_provider) : nil
      default_model = provider_preset ? provider_preset["default_model"] : model["model"]
      default_base_url = provider_preset ? provider_preset["base_url"] : model["base_url"]
      masked_key = mask_api_key(model["api_key"])

      fields = [
        {
          name: :api_key,
          label: "API Key #{is_new ? "" : "(current: #{masked_key})"}:",
          default: "",
          mask: true,
          placeholder: is_new ? "required" : "leave blank to keep current"
        },
        {
          name: :model,
          label: "Model #{is_new && default_model ? "(default: #{default_model})" : (is_new ? "" : "(current: #{model["model"]})")}:",
          default: default_model || "",
          placeholder: "model name"
        },
        {
          name: :base_url,
          label: "Base URL #{is_new && default_base_url ? "(default: #{default_base_url})" : (is_new ? "" : "(current: #{model["base_url"]})")}:",
          default: default_base_url || "",
          placeholder: "https://..."
        }
      ]

      title = if is_new && selected_provider && selected_provider != "custom"
                provider_name = Clacky::Providers.get(selected_provider)&.dig("name") || selected_provider
                "Add #{provider_name} Model"
              elsif is_new
                "Add Custom Model"
              else
                "Edit Model"
              end

      loop do
        result = show_form_dialog(title: title, fields: fields)
        return nil if result.nil?

        values = merge_model_form_values(
          result,
          model: model,
          default_model: default_model,
          default_base_url: default_base_url
        )

        validation = validate_model_form(values, is_new: is_new, existing_model: model, test_callback: test_callback)
        if validation[:success]
          return values.merge(provider: selected_provider)
        end

        show_warning(validation[:error])
        fields.each { |field| field[:default] = result[field[:name]].to_s }
      end
    end

    def show_provider_selection
      choices = Clacky::Providers.list.map { |id, name| { label: name, value: id } }
      choices << { label: "─" * 40, disabled: true }
      choices << { label: "Custom (manual configuration)", value: "custom" }
      show_menu_dialog(title: "Select Provider", choices: choices, selected_index: 0)
    end

    def merge_model_form_values(result, model:, default_model:, default_base_url:)
      {
        api_key: result[:api_key].to_s.empty? ? model["api_key"] : result[:api_key],
        model: result[:model].to_s.empty? ? (model["model"] || default_model) : result[:model],
        base_url: result[:base_url].to_s.empty? ? (model["base_url"] || default_base_url) : result[:base_url]
      }
    end

    def validate_model_form(values, is_new:, existing_model:, test_callback:)
      if is_new
        return { success: false, error: "API Key is required for new model" } if values[:api_key].to_s.empty?
        return { success: false, error: "Model name is required" } if values[:model].to_s.empty?
        return { success: false, error: "Base URL is required" } if values[:base_url].to_s.empty?
      end

      return { success: true } unless test_callback

      temp_config = Clacky::AgentConfig.new(
        models: [{
          "api_key" => values[:api_key],
          "model" => values[:model],
          "base_url" => values[:base_url],
          "anthropic_format" => existing_model["anthropic_format"]
        }],
        current_model_index: 0
      )
      test_callback.call(temp_config)
    end

    def format_args(args)
      data = args.is_a?(String) ? (JSON.parse(args) rescue args) : args
      data.is_a?(Hash) ? JSON.pretty_generate(data) : data.to_s
    end

    def normalize_todo(todo)
      case todo
      when Hash
        title = todo[:content] || todo["content"] || todo[:title] || todo["title"] || todo[:task] || todo["task"]
        status = todo[:status] || todo["status"] || :pending
        { title: title.to_s, status: status.to_sym }
      else
        { title: todo.to_s, status: :pending }
      end
    end

    def mask_api_key(api_key)
      key = api_key.to_s
      return "not set" if key.empty?

      "#{key[0..5]}...#{key[-4..]}"
    end

    class LayoutAdapter
      def initialize(shell)
        @shell = shell
      end

      def clear_output
        @shell.transcript.store.entries.clear
        @shell.viewport.scroll_to_bottom
      end
    end

    class ProgressHandleAdapter
      def initialize(handle)
        @handle = handle
      end

      def update(message: nil, metadata: nil)
        _ = metadata
        @handle.update(message.to_s) if message
      end

      def finish(final_message: nil)
        final_message ? @handle.finish(final_message.to_s) : @handle.finish
      end

      def cancel
        @handle.cancel
      end
    end

    class ConfigMenuDialog
      attr_accessor :width, :height

      def initialize(choices:, selected_index: 0, title: "Model Configuration", width: 86)
        @choices = choices
        @selected_index = selected_index
        @width = width
        @height = [choices.length + 7, 12].max
        @event_listeners = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @panel = RubyRich::Panel.new("", title: title, border_style: :cyan, title_align: :center)
        @layout = RubyRich::Layout.new(name: :config_dialog, width: @width, height: @height)
        @layout.update_content(@panel)
        @layout.calculate_dimensions(@width, @height)
      end

      def selected_choice
        @choices[@selected_index]
      end

      def move_up
        move(-1)
      end

      def move_down
        move(1)
      end

      def finish(value)
        @mutex.synchronize do
          @result = value
          @finished = true
          @condition.signal
        end
        true
      end

      def wait
        @mutex.synchronize { @condition.wait(@mutex) until @finished }
        @result
      end

      def key(event_name, priority = 0, &block)
        @event_listeners[event_name] ||= []
        @event_listeners[event_name] << { priority: priority, block: block }
        @event_listeners[event_name].sort_by! { |listener| -listener[:priority] }
      end

      def notify_listeners(event_data)
        Array(@event_listeners[event_data[:name]]).each { |listener| listener[:block].call(event_data, nil) }
      end

      def render_to_buffer
        @panel.content = render_content
        @layout.calculate_dimensions(@width, @height)
        @layout.render_to_buffer
      end

      private

      def move(delta)
        return if @choices.empty?

        index = @selected_index
        loop do
          index = (index + delta) % @choices.length
          break unless @choices[index][:disabled]
          break if index == @selected_index
        end
        @selected_index = index
      end

      def render_content
        lines = [""]
        @choices.each_with_index do |choice, index|
          lines << choice_line(choice, selected: index == @selected_index)
        end
        lines << ""
        lines << "#{muted("↑↓/jk: Navigate")} • #{muted("Enter: Select")} • #{muted("Esc/q: Cancel")}"
        lines.join("\n")
      end

      def choice_line(choice, selected:)
        return "  #{muted(choice[:label])}" if choice[:disabled]

        prefix = selected ? "#{RubyRich::AnsiCode.color(:cyan, true)}➜#{RubyRich::AnsiCode.reset} " : "  "
        label = selected ? RubyRich::AnsiCode.color(:white, true) + choice[:label] + RubyRich::AnsiCode.reset : choice[:label]
        "#{prefix}#{label}"
      end

      def muted(text)
        "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end
    end

    class FormDialog
      attr_accessor :width, :height

      def initialize(title:, fields:, width: 92)
        @title = title
        @fields = fields
        @field_index = 0
        @editors = fields.map do |field|
          RubyRich::LineEditor.new.tap { |editor| editor.value = field[:default].to_s }
        end
        @width = width
        @height = [fields.length * 3 + 8, 16].max
        @event_listeners = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @panel = RubyRich::Panel.new("", title: title, border_style: :cyan, title_align: :center)
        @layout = RubyRich::Layout.new(name: :form_dialog, width: @width, height: @height)
        @layout.update_content(@panel)
        @layout.calculate_dimensions(@width, @height)
        wire_default_keys
      end

      def finish(value)
        @mutex.synchronize do
          @result = value
          @finished = true
          @condition.signal
        end
        true
      end

      def wait
        @mutex.synchronize { @condition.wait(@mutex) until @finished }
        @result
      end

      def key(event_name, priority = 0, &block)
        @event_listeners[event_name] ||= []
        @event_listeners[event_name] << { priority: priority, block: block }
        @event_listeners[event_name].sort_by! { |listener| -listener[:priority] }
      end

      def notify_listeners(event_data)
        listeners = Array(@event_listeners[event_data[:name]])
        listeners.each { |listener| listener[:block].call(event_data, nil) }
      end

      def render_to_buffer
        @panel.content = render_content
        @layout.calculate_dimensions(@width, @height)
        @layout.render_to_buffer
      end

      private

      def wire_default_keys
        key(:string, 100) { |event, _live| current_editor.insert(event[:value]); true }
        key(:paste, 100) { |event, _live| current_editor.insert(event[:value]); true }
        key(:backspace, 100) { current_editor.backspace; true }
        key(:delete, 100) { current_editor.delete; true }
        key(:left, 100) { current_editor.move_left; true }
        key(:right, 100) { current_editor.move_right; true }
        key(:ctrl_a, 100) { current_editor.buffer_start; true }
        key(:ctrl_e, 100) { current_editor.buffer_end; true }
        key(:up, 100) { move_field(-1); true }
        key(:down, 100) { move_field(1); true }
        key(:tab, 100) { move_field(1); true }
        key(:shift_tab, 100) { move_field(-1); true }
        key(:enter, 100) { finish(values); true }
      end

      def current_editor
        @editors[@field_index]
      end

      def move_field(delta)
        @field_index = (@field_index + delta) % @fields.length
      end

      def values
        @fields.each_with_index.to_h { |field, index| [field[:name].to_sym, @editors[index].value] }
      end

      def render_content
        lines = [""]
        @fields.each_with_index do |field, index|
          focused = index == @field_index
          marker = focused ? "#{RubyRich::AnsiCode.color(:cyan, true)}➜#{RubyRich::AnsiCode.reset}" : " "
          label = focused ? "#{RubyRich::AnsiCode.color(:white, true)}#{field[:label]}#{RubyRich::AnsiCode.reset}" : field[:label]
          lines << "#{marker} #{label}"
          lines << "  #{render_field_value(field, @editors[index], focused: focused)}"
          lines << ""
        end
        lines << "#{muted("Tab/↑↓: Field")} • #{muted("Enter: Save")} • #{muted("Esc: Cancel")}"
        lines.join("\n")
      end

      def render_field_value(field, editor, focused:)
        raw = editor.value
        text = if field[:mask] && !raw.empty?
                 "*" * raw.length
               elsif raw.empty?
                 field[:placeholder].to_s
               else
                 raw
               end
        color = raw.empty? ? :black : (focused ? :cyan : :white)
        "#{RubyRich::AnsiCode.color(color, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end

      def muted(text)
        "#{RubyRich::AnsiCode.color(:black, true)}#{text}#{RubyRich::AnsiCode.reset}"
      end
    end
  end
end
