# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "base"
require_relative "../trash_directory"

module Clacky
  module Tools
    class TrashManager < Base
      self.tool_name = "trash_manager"
      self.tool_description = "Manage deleted files in the AI trash - list, restore, or permanently delete files"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["list", "restore", "status", "empty", "help"],
            description: "Action to perform: 'list' (show deleted files), 'restore' (restore a file), 'status' (show trash summary), 'empty' (permanently delete old files), 'help' (show usage)"
          },
          file_path: {
            type: "string",
            description: "Original file path to restore (required for 'restore' action)"
          },
          days_old: {
            type: "integer",
            description: "For 'empty' action: permanently delete files older than this many days (default: 7)"
          }
        },
        required: ["action"]
      }

      def execute(action:, file_path: nil, days_old: 7)
        project_root = Dir.pwd
        
        # Use global trash directory organized by project
        trash_directory = Clacky::TrashDirectory.new(project_root)
        trash_dir = trash_directory.trash_dir

        unless Dir.exist?(trash_dir)
          return {
            action: action,
            success: false,
            message: "No trash directory found. No files have been safely deleted yet."
          }
        end

        case action.downcase
        when 'list'
          list_deleted_files(trash_dir, project_root)
        when 'restore'
          return { action: action, success: false, message: "file_path is required for restore action" } unless file_path
          restore_file(trash_dir, file_path, project_root)
        when 'status'
          show_trash_status(trash_dir, project_root)
        when 'empty'
          empty_trash(trash_dir, days_old, project_root)
        when 'help'
          show_help
        else
          { action: action, success: false, message: "Unknown action: #{action}" }
        end
      end

      def list_deleted_files(trash_dir, project_root)
        deleted_files = get_deleted_files(trash_dir, project_root)

        if deleted_files.empty?
          return {
            action: 'list',
            success: true,
            count: 0,
            message: "🗑️  Trash is empty"
          }
        end

        file_list = deleted_files.map.with_index(1) do |file, index|
          size_info = file[:file_size] ? " (#{format_bytes(file[:file_size])})" : ""
          "#{index}. #{file[:original_path]}#{size_info}\n   Deleted: #{format_time(file[:deleted_at])}"
        end

        {
          action: 'list',
          success: true,
          count: deleted_files.size,
          files: deleted_files,
          message: "🗑️  Deleted Files:\n\n#{file_list.join("\n\n")}\n\n💡 Use trash_manager with action='restore' and file_path='<path>' to restore a file"
        }
      end

      def restore_file(trash_dir, file_path, project_root)
        deleted_files = get_deleted_files(trash_dir, project_root)
        expanded_path = File.expand_path(file_path, project_root)

        target_file = deleted_files.find { |f| f[:original_path] == expanded_path }

        unless target_file
          similar_files = deleted_files.select { |f| File.basename(f[:original_path]) == File.basename(file_path) }

          if similar_files.any?
            suggestions = similar_files.map { |f| f[:original_path] }.join("\n  - ")
            return {
              action: 'restore',
              success: false,
              message: "File not found in trash: #{file_path}\n\nDid you mean one of these?\n  - #{suggestions}"
            }
          else
            return {
              action: 'restore',
              success: false,
              message: "File not found in trash: #{file_path}\n\nUse trash_manager with action='list' to see available files."
            }
          end
        end

        if File.exist?(expanded_path)
          return {
            action: 'restore',
            success: false,
            message: "Cannot restore: file already exists at #{file_path}"
          }
        end

        begin
          # Ensure target directory exists
          FileUtils.mkdir_p(File.dirname(expanded_path))

          # Restore file
          FileUtils.mv(target_file[:trash_file], expanded_path)
          File.delete("#{target_file[:trash_file]}.metadata.json")

          {
            action: 'restore',
            success: true,
            restored_file: expanded_path,
            message: "✅ Successfully restored: #{file_path}"
          }
        rescue StandardError => e
          {
            action: 'restore',
            success: false,
            message: "❌ Failed to restore file: #{e.message}"
          }
        end
      end

      def show_trash_status(trash_dir, project_root)
        deleted_files = get_deleted_files(trash_dir, project_root)
        total_size = deleted_files.sum { |f| f[:file_size] || 0 }

        if deleted_files.empty?
          return {
            action: 'status',
            success: true,
            count: 0,
            total_size: 0,
            message: "🗑️  Trash is empty"
          }
        end

        # Group by file type
        by_type = deleted_files.group_by { |f| f[:file_type] || 'no extension' }
        type_summary = by_type.map do |ext, files|
          size = files.sum { |f| f[:file_size] || 0 }
          "  #{ext}: #{files.size} files (#{format_bytes(size)})"
        end.join("\n")

        recent_files = deleted_files.first(3).map do |file|
          "  - #{File.basename(file[:original_path])} (#{format_time(file[:deleted_at])})"
        end.join("\n")

        message = []
        message << "🗑️  Trash Status:"
        message << "  Files: #{deleted_files.count}"
        message << "  Total size: #{format_bytes(total_size)}"
        message << "  Location: #{trash_dir}"
        message << ""
        message << "📊 By file type:"
        message << type_summary
        message << ""
        message << "📅 Recently deleted:"
        message << recent_files

        {
          action: 'status',
          success: true,
          count: deleted_files.size,
          total_size: total_size,
          by_type: by_type.transform_values(&:size),
          message: message.join("\n")
        }
      end

      def empty_trash(trash_dir, days_old, project_root)
        deleted_files = get_deleted_files(trash_dir, project_root)
        cutoff_time = Time.now - (days_old * 24 * 60 * 60)

        old_files = deleted_files.select do |file|
          Time.parse(file[:deleted_at]) < cutoff_time
        end

        if old_files.empty?
          return {
            action: 'empty',
            success: true,
            deleted_count: 0,
            message: "🗑️  No files older than #{days_old} days found in trash"
          }
        end

        deleted_count = 0
        freed_size = 0

        old_files.each do |file|
          begin
            File.delete(file[:trash_file]) if File.exist?(file[:trash_file])
            File.delete("#{file[:trash_file]}.metadata.json") if File.exist?("#{file[:trash_file]}.metadata.json")
            deleted_count += 1
            freed_size += file[:file_size] || 0
          rescue StandardError => e
            # Continue processing other files, but log the error
          end
        end

        {
          action: 'empty',
          success: true,
          deleted_count: deleted_count,
          freed_size: freed_size,
          days_old: days_old,
          message: "🗑️  Permanently deleted #{deleted_count} files older than #{days_old} days\n💾 Freed up #{format_bytes(freed_size)} of disk space"
        }
      end

      def show_help
        help_text = <<~HELP
          🗑️ Trash Manager Help

          The SafeShell tool automatically moves deleted files to a trash directory
          instead of permanently deleting them. This tool helps you manage those files.

          Available actions:

          📋 list - Show all deleted files
          Example: trash_manager(action="list")

          ♻️  restore - Restore a deleted file to its original location
          Example: trash_manager(action="restore", file_path="path/to/file.txt")

          📊 status - Show trash summary with statistics
          Example: trash_manager(action="status")

          🗑️  empty - Permanently delete files older than N days (default: 7)
          Example: trash_manager(action="empty", days_old=7)

          ❓ help - Show this help message

          💡 Tips:
          - Use 'list' to see what files are in trash
          - Use 'restore' to get back accidentally deleted files
          - Use 'empty' periodically to free up disk space
          - All deletions by SafeShell are logged in .ai_safety.log
        HELP

        {
          action: 'help',
          success: true,
          message: help_text
        }
      end

      def get_deleted_files(trash_dir, project_root)
        deleted_files = []

        Dir.glob(File.join(trash_dir, "*.metadata.json")).each do |metadata_file|
          begin
            metadata = JSON.parse(File.read(metadata_file))
            trash_file = metadata_file.sub('.metadata.json', '')

            # Only include existing trash files
            if File.exist?(trash_file)
              deleted_files << {
                original_path: metadata['original_path'],
                deleted_at: metadata['deleted_at'],
                trash_file: trash_file,
                file_size: metadata['file_size'],
                file_type: metadata['file_type'],
                file_mode: metadata['file_mode']
              }
            end
          rescue StandardError
            # Skip corrupted metadata files
          end
        end

        deleted_files.sort_by { |f| f[:deleted_at] }.reverse
      end

      def format_bytes(bytes)
        return "0 B" if bytes.zero?

        units = %w[B KB MB GB]
        unit_index = 0
        size = bytes.to_f

        while size >= 1024 && unit_index < units.length - 1
          size /= 1024.0
          unit_index += 1
        end

        if unit_index == 0
          "#{size.to_i} #{units[unit_index]}"
        else
          "#{size.round(2)} #{units[unit_index]}"
        end
      end

      def format_time(time_str)
        time = Time.parse(time_str)
        if time.to_date == Date.today
          time.strftime("%H:%M")
        elsif time.to_date == Date.today - 1
          "yesterday #{time.strftime('%H:%M')}"
        elsif time.year == Date.today.year
          time.strftime("%m/%d %H:%M")
        else
          time.strftime("%Y/%m/%d")
        end
      rescue
        time_str
      end

      def format_call(args)
        action = args[:action] || args['action'] || 'unknown'
        "TrashManager(#{action})"
      end

      def format_result(result)
        action = result[:action] || 'unknown'
        success = result[:success]

        case action
        when 'list'
          count = result[:count] || 0
          "📋 Listed #{count} deleted files"
        when 'restore'
          if success
            "♻️ File restored successfully"
          else
            "❌ Restore failed"
          end
        when 'status'
          count = result[:count] || 0
          "📊 Trash: #{count} files"
        when 'empty'
          if success
            deleted_count = result[:deleted_count] || 0
            "🗑️ Emptied #{deleted_count} files"
          else
            "❌ Empty failed"
          end
        when 'help'
          "❓ Help displayed"
        else
          success ? "✓ #{action} completed" : "✗ #{action} failed"
        end
      end
    end
  end
end
