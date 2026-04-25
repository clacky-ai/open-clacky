# frozen_string_literal: true

module Clacky
  class Agent
    # Long-term memory update functionality.
    #
    # Runs at the end of a qualifying task to persist important knowledge
    # into ~/.clacky/memories/. The LLM decides:
    #   - Which topics were discussed
    #   - Which memory files to update or create
    #   - How to merge new info with existing content
    #   - What to drop to stay within the per-file token limit
    #
    # Architecture:
    #   Memory update runs as a **forked subagent**, NOT inline in the
    #   main agent's loop. The subagent inherits the main agent's history
    #   (so it can see what happened) via +fork_subagent+'s standard
    #   deep-clone, and inherits the same model/tools so prompt-cache is
    #   reused maximally. The subagent runs synchronously; when it returns,
    #   the main agent prints +show_complete+.
    #
    #   This gives us, structurally:
    #     - Clean main-agent history (no memory_update messages to clean up)
    #     - Correct visual ordering ([OK] Task Complete is the LAST thing
    #       printed — the memory-update progress finishes before it)
    #     - Independent cost accounting (task cost vs. memory update cost)
    #     - Natural recursion guard (+@is_subagent+ blocks re-entry)
    #
    # Trigger condition:
    #   - Iteration count >= MEMORY_UPDATE_MIN_ITERATIONS (skip trivial tasks)
    #   - Not already a subagent (no recursion)
    #   - Memory update is enabled in config
    module MemoryUpdater
      # Minimum LLM iterations for this task before triggering memory update.
      # Set high enough to skip short utility tasks (commit, deploy, etc.)
      MEMORY_UPDATE_MIN_ITERATIONS = 10

      MEMORIES_DIR = File.expand_path("~/.clacky/memories")

      # Check if memory update should be triggered for this task.
      # Only triggers when the task had enough LLM iterations,
      # skipping short utility tasks (e.g. commit, deploy).
      # @return [Boolean]
      def should_update_memory?
        return false unless memory_update_enabled?
        return false if @is_subagent  # Subagents never update memory

        task_iterations = @iterations - (@task_start_iterations || 0)
        task_iterations >= MEMORY_UPDATE_MIN_ITERATIONS
      end

      # Run memory update as a forked subagent.
      #
      # This is called by +Agent#run+ on the success path, AFTER the main
      # loop exits and BEFORE +show_complete+ is printed. It blocks until
      # the subagent finishes, so the visual order is structurally correct:
      #
      #   ... task output ...
      #   [progress] Updating long-term memory… (spinner)
      #   [progress finishes]
      #   [OK] Task Complete
      #
      # Safe to call unconditionally; returns early if preconditions fail.
      # Never raises for "no update needed" — only propagates genuine errors
      # (+Clacky::AgentInterrupted+ for Ctrl+C, other exceptions are caught
      # and logged so memory-update failures never mask the parent task's
      # result).
      def run_memory_update_subagent
        return unless should_update_memory?

        handle = @ui&.start_progress(message: "Updating long-term memory…", style: :primary)

        # Fork subagent inheriting main agent's model, tools, and history.
        # Maximizes prompt-cache reuse: same model, same tool set, same
        # cloned history — only the +system_prompt_suffix+ (the memory
        # update instructions) and the final "Please proceed." user turn
        # are new, landing on top of a warm cache.
        subagent = fork_subagent(system_prompt_suffix: build_memory_update_prompt)

        # Memory update is a background consolidation task — never prompt
        # the user for confirmation on memory file writes. The subagent
        # has its own config copy (fork_subagent does deep_copy), so this
        # doesn't affect the parent.
        sub_config = subagent.instance_variable_get(:@config)
        sub_config.permission_mode = :auto_approve if sub_config.respond_to?(:permission_mode=)

        begin
          result = subagent.run("Please proceed.")
        rescue Clacky::AgentInterrupted
          # User pressed Ctrl+C during memory update. Propagate so the
          # parent agent's interrupt handler runs.
          raise
        rescue StandardError => e
          # Memory update failures are NEVER fatal to the parent task.
          # Log and move on — the user's actual work is already done.
          @debug_logs << {
            timestamp: Time.now.iso8601,
            event: "memory_update_error",
            error_class: e.class.name,
            error_message: e.message,
            backtrace: e.backtrace&.first(10)
          }
          Clacky::Logger.error("memory_update_error", error: e)
          return
        ensure
          handle&.finish
        end

        return unless result

        # Merge subagent cost into parent's cumulative session spend so the
        # sessionbar shows the real total. The parent's task-complete cost
        # (result[:total_cost_usd] in Agent#run) stays unaffected — it
        # still reflects ONLY the user's task, not the memory update.
        subagent_cost = result[:total_cost_usd] || 0.0
        @total_cost += subagent_cost
        @ui&.update_sessionbar(cost: @total_cost, cost_source: @cost_source)

        # Only surface a completion info line if the subagent actually
        # wrote something to memory. The common "No memory updates needed."
        # path stays silent to avoid visual noise.
        if subagent_wrote_memory?(subagent)
          @ui&.show_info("Memory updated: #{result[:iterations]} iterations, $#{subagent_cost.round(4)}")
        end
      end

      private def memory_update_enabled?
        # Check config flag; default to true if not set
        return true unless @config.respond_to?(:memory_update_enabled)

        @config.memory_update_enabled != false
      end

      # Inspect the subagent's history for a successful write/edit tool
      # call targeting a memory file. Used to decide whether to surface a
      # "Memory updated" info line (option C — silent when nothing changed).
      # @param subagent [Clacky::Agent]
      # @return [Boolean]
      private def subagent_wrote_memory?(subagent)
        return false unless subagent.respond_to?(:history) && subagent.history

        subagent.history.to_a.any? do |msg|
          next false unless msg.is_a?(Hash)

          # Match OpenAI-style tool_calls on assistant messages …
          tool_calls = msg[:tool_calls] || msg["tool_calls"]
          if tool_calls.is_a?(Array) && tool_calls.any?
            next true if tool_calls.any? do |tc|
              name = tc.dig(:function, :name) || tc.dig("function", "name") || tc[:name] || tc["name"]
              %w[write edit].include?(name.to_s)
            end
          end

          # … and Anthropic-style content blocks with type=tool_use.
          content = msg[:content] || msg["content"]
          if content.is_a?(Array)
            next true if content.any? do |block|
              block.is_a?(Hash) &&
                (block[:type] == "tool_use" || block["type"] == "tool_use") &&
                %w[write edit].include?((block[:name] || block["name"]).to_s)
            end
          end

          false
        end
      rescue StandardError
        # Defensive: never let introspection errors break memory update.
        false
      end

      # Build the memory update prompt with the current memory file list injected.
      # Uses a whitelist approach: default is NO write, only write if explicit criteria are met.
      # @return [String]
      private def build_memory_update_prompt
        today = Time.now.strftime("%Y-%m-%d")
        meta  = load_memories_meta

        <<~PROMPT
          ═══════════════════════════════════════════════════════════════
          MEMORY UPDATE MODE
          ═══════════════════════════════════════════════════════════════
          The conversation above has ended. You are now in MEMORY UPDATE MODE.

          ## Default: Do NOT write anything.

          Memory writes are expensive. Only write if the session contains at least one of the
          following high-value signals. If NONE apply, respond immediately with:
          "No memory updates needed." and STOP — do not use any tools.

          ## Whitelist: Write ONLY if at least one condition is met

          1. **Explicit decision** — The user made a clear technical, product, or process decision
             that will affect future work (e.g. "we'll use X instead of Y going forward").
          2. **New persistent context** — The user introduced project background, constraints, or
             goals that are not already obvious from the code (e.g. a new feature direction,
             a deployment target, a team convention).
          3. **Correction of prior knowledge** — The user corrected a previous misunderstanding
             or the agent discovered that an existing memory is wrong or outdated.
          4. **Stated preference** — The user expressed a clear personal or team preference about
             how they want the agent to behave, communicate, or write code.

          ## What does NOT qualify (skip these entirely)

          - Running tests, fixing lint, formatting code
          - Committing, deploying, or releasing
          - Answering a one-off question or explaining a concept
          - Any task that produced no lasting decisions or preferences
          - Repeating or slightly rephrasing what is already in memory

          ## Existing Memory Files (pre-loaded — do NOT re-scan the directory)

          #{meta}

          Each file has YAML frontmatter:
          ```
          ---
          topic: <topic name>
          description: <one-line description>
          updated_at: <YYYY-MM-DD>
          ---
          <content in concise Markdown>
          ```

          ## Steps (only if a whitelist condition is met)

          For each qualifying topic:
            a. If a matching file exists → read it with `file_reader(path: "~/.clacky/memories/<filename>")`, then write an updated version (merge new + old, drop stale)
            b. If no matching file → create a new one at `~/.clacky/memories/<new-filename>.md`
          Use the `write` tool to save each file. Do NOT use `terminal` or `file_reader` to list the directory.

          ## Hard constraints (CRITICAL)
          - Each file MUST stay under 4000 characters of content (after the frontmatter)
          - If merging would exceed this limit, remove the least important information
          - Write concise, factual Markdown — no fluff
          - Update `updated_at` to today's date: #{today}
          - Only write files for topics that genuinely appeared in this conversation

          Begin by checking the whitelist. If no condition is met, stop immediately.
        PROMPT
      end
    end
  end
end
