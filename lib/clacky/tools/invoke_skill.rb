# frozen_string_literal: true

module Clacky
  module Tools
    # Tool for invoking skills within the agent
    # This allows the AI to call skills as tools rather than requiring explicit user commands
    class InvokeSkill < Base
      self.tool_name = "invoke_skill"
      self.tool_description = "Invoke a specialized skill to handle specific tasks. Use this when user's request matches a skill's purpose (e.g., code exploration, document creation, etc.). This will read the skill's instructions and execute them appropriately (either inline or in a subagent)."
      self.tool_category = "skill_management"
      self.tool_parameters = {
        type: "object",
        properties: {
          skill_name: {
            type: "string",
            description: "Name of the skill to invoke (e.g., 'code-explorer', 'pptx', 'pdf')"
          },
          task: {
            type: "string",
            description: "The task or query to pass to the skill"
          }
        },
        required: ["skill_name", "task"]
      }

      # Execute the skill invocation
      # @param skill_name [String] Name of the skill to invoke
      # @param task [String] Task description to pass to the skill
      # @param agent [Clacky::Agent] Agent instance (injected)
      # @param skill_loader [Clacky::SkillLoader] Skill loader instance (injected)
      # @return [Hash] Result of skill execution
      def execute(skill_name:, task:, agent: nil, skill_loader: nil, working_dir: nil)
        # Validate injected dependencies
        return { error: "Agent context is required" } unless agent
        return { error: "Skill loader is required" } unless skill_loader

        # Find skill by name
        skill = skill_loader.find_by_name(skill_name)
        return { error: "Skill not found: #{skill_name}" } unless skill

        # Check if skill allows model invocation
        unless skill.model_invocation_allowed?
          return { error: "Skill '#{skill_name}' does not allow model invocation" }
        end

        # Execute skill based on its configuration
        if skill.fork_agent?
          # Execute in subagent - use private method via send
          result = agent.send(:execute_skill_with_subagent, skill, task)
          {
            message: "Skill '#{skill_name}' executed in subagent",
            result: result,
            skill_type: "subagent"
          }
        else
          # Expand skill content inline
          expanded = skill.process_content(task)
          
          # Add skill directory path information for script execution
          skill_dir_info = "\n\n---\n**Skill Directory:** `#{skill.directory}`\n\nWhen executing scripts from Supporting Files, use the full path:\n`#{skill.directory}/scripts/script_name`\n---\n"
          
          {
            message: "Skill '#{skill_name}' content expanded",
            content: expanded + skill_dir_info,
            skill_type: "inline",
            note: "The expanded content has been added to the conversation. Continue following its instructions."
          }
        end
      end

      # Format the tool call for display
      # @param args [Hash] Tool arguments
      # @return [String] Formatted call description
      def format_call(args)
        skill = args[:skill_name] || args["skill_name"]
        "InvokeSkill(#{skill})"
      end

      # Format the tool result for display
      # @param result [Hash] Tool execution result
      # @return [String] Formatted result summary
      def format_result(result)
        if result[:error]
          "Error: #{result[:error]}"
        elsif result[:skill_type] == "subagent"
          "Subagent executed successfully"
        else
          "Skill content expanded"
        end
      end
    end
  end
end
