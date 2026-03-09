# frozen_string_literal: true

module Clacky
  class Agent
    # System prompt construction
    # Builds system prompt by composing layers:
    #   1. Agent-specific system_prompt.md  (role & responsibilities)
    #   2. base_prompt.md                   (universal rules: todo manager, tool usage, etc.)
    #   3. Project rules                    (.clackyrules / .cursorrules / CLAUDE.md)
    #   4. SOUL.md                          (agent personality — user override or built-in default)
    #   5. USER.md                          (user profile — user override or built-in default)
    #   6. Skills context                   (available skills list)
    module SystemPromptBuilder
      # Max characters loaded from each agent file (SOUL.md / USER.md)
      MAX_MEMORY_FILE_CHARS = 1000

      # Build complete system prompt with project rules and skills
      # @return [String] Complete system prompt
      def build_system_prompt
        parts = []

        # Layer 1: agent-specific role & responsibilities
        parts << @agent_profile.system_prompt

        # Layer 2: universal behavioral rules (todo manager, tool usage, etc.)
        base = @agent_profile.base_prompt
        parts << base unless base.empty?

        # Layer 3: project-specific rules from working directory
        project_rules = load_project_rules
        if project_rules
          parts << format_section("PROJECT-SPECIFIC RULES (from #{project_rules[:source]})",
                                  project_rules[:content],
                                  footer: "IMPORTANT: Follow these project-specific rules at all times!")
        end

        # Layer 4 & 5: SOUL.md and USER.md (with built-in defaults as fallback)
        soul = truncate(@agent_profile.soul, MAX_MEMORY_FILE_CHARS)
        parts << format_section("AGENT SOUL (from ~/.clacky/agents/SOUL.md)", soul) unless soul.empty?

        user_profile = truncate(@agent_profile.user_profile, MAX_MEMORY_FILE_CHARS)
        parts << format_section("USER PROFILE (from ~/.clacky/agents/USER.md)", user_profile) unless user_profile.empty?

        # Layer 6: skills context
        skill_context = build_skill_context
        parts << skill_context if skill_context && !skill_context.empty?

        parts.join("\n\n")
      end

      private def load_project_rules
        rules_files = [
          { path: ".clackyrules", name: ".clackyrules" },
          { path: ".cursorrules", name: ".cursorrules" },
          { path: "CLAUDE.md",    name: "CLAUDE.md" }
        ]

        rules_files.each do |file_info|
          full_path = File.join(@working_dir, file_info[:path])
          next unless File.exist?(full_path)

          content = File.read(full_path).strip
          return { content: content, source: file_info[:name] } unless content.empty?
        end

        nil
      end

      private def format_section(title, content, footer: nil)
        sep = "=" * 80
        lines = ["", sep, title, sep, content, sep]
        lines << footer if footer
        lines << sep if footer
        lines.join("\n")
      end

      private def truncate(text, max_chars)
        return text if text.length <= max_chars

        text[0, max_chars] + "\n... [truncated]"
      end
    end
  end
end
