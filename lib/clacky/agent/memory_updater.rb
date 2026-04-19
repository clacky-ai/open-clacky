# frozen_string_literal: true

module Clacky
  class Agent
    # Long-term memory update functionality
    # Triggered at the end of a session to persist important knowledge.
    #
    # The LLM decides:
    #   - Which topics were discussed
    #   - Which memory files to update or create
    #   - How to merge new info with existing content
    #   - What to drop to stay within the per-file token limit
    #
    # Trigger condition:
    #   - Iteration count >= MEMORY_UPDATE_MIN_ITERATIONS (avoids trivial tasks like commits)
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

      # Inject memory update prompt into @messages so the main agent loop handles it.
      # Builds the prompt dynamically, injecting the current memory file list so the
      # LLM doesn't need to scan the directory itself.
      # Returns true if prompt was injected, false otherwise.
      def inject_memory_prompt!
        return false unless should_update_memory?
        return false if @memory_prompt_injected

        @memory_prompt_injected = true
        @memory_updating = true
        @ui&.show_progress("Updating long-term memory…")

        @history.append({
          role: "user",
          content: build_memory_update_prompt,
          system_injected: true,
          memory_update: true
        })

        true
      end

      # Clean up memory update messages from conversation history after loop ends.
      # Call this once after the main loop finishes.
      def cleanup_memory_messages
        return unless @memory_prompt_injected

        @history.delete_where { |m| m[:memory_update] }
        @memory_prompt_injected = false
        @memory_updating = false
        @ui&.show_progress(phase: "done")
      end

      private def memory_update_enabled?
        # Check config flag; default to true if not set
        return true unless @config.respond_to?(:memory_update_enabled)

        @config.memory_update_enabled != false
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
          Use the `write` tool to save each file. Do NOT use `safe_shell` or `file_reader` to list the directory.

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
