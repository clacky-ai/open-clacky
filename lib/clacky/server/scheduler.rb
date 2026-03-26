# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  module Server
    # Scheduler reads ~/.clacky/schedules.yml and runs tasks on a cron-like schedule.
    #
    # It starts a background thread that ticks every 60 seconds, checks all
    # configured schedules, and fires any task whose cron expression matches
    # the current time.
    #
    # Schedule file format (~/.clacky/schedules.yml):
    #
    #   - name: daily_report
    #     task: daily_report          # references ~/.clacky/tasks/daily_report.md
    #     cron: "0 9 * * 1-5"        # standard 5-field cron expression
    #     enabled: true               # optional, defaults to true
    #
    # Cron field order: minute hour day-of-month month day-of-week
    class Scheduler
      SCHEDULES_FILE = File.expand_path("~/.clacky/schedules.yml")
      TASKS_DIR      = File.expand_path("~/.clacky/tasks")

      def initialize(session_registry:, session_builder:)
        @registry        = session_registry
        @session_builder = session_builder  # callable: (name:, working_dir:) -> session_id
        @thread          = nil
        @running         = false
        @mutex           = Mutex.new
      end

      # Start the background scheduler thread.
      def start
        @mutex.synchronize do
          return if @running

          @running = true
          @thread  = Thread.new { run_loop }
          @thread.name = "clacky-scheduler"
        end
      end

      # Stop the background scheduler thread gracefully.
      # NOTE: intentionally avoids Mutex here so it is safe to call from a
      # signal trap context (Ruby disallows Mutex#synchronize inside traps).
      def stop
        @running = false
        @thread&.wakeup rescue nil
        @thread&.join(5)
      end

      def running?
        @running
      end

      # Return all schedules from the config file.
      def schedules
        load_schedules
      end

      # ── Schedule CRUD ────────────────────────────────────────────────────────

      # Add or update a schedule entry in schedules.yml.
      def add_schedule(name:, task:, cron:, enabled: true)
        list = load_schedules
        # Remove existing entry with the same name
        list.reject! { |s| s["name"] == name }
        list << {
          "name"    => name,
          "task"    => task,
          "cron"    => cron,
          "enabled" => enabled
        }
        save_schedules(list)
      end

      # Remove a schedule entry by name.
      def remove_schedule(name)
        list = load_schedules
        before_count = list.size
        list.reject! { |s| s["name"] == name }
        save_schedules(list)
        list.size < before_count
      end

      # ── Task file helpers ────────────────────────────────────────────────────

      # Read the prompt content of a named task.
      def read_task(task_name)
        path = task_file_path(task_name)
        raise "Task not found: #{task_name} (expected #{path})" unless File.exist?(path)

        File.read(path)
      end

      # Write the prompt content for a named task.
      def write_task(task_name, content)
        FileUtils.mkdir_p(TASKS_DIR)
        File.write(task_file_path(task_name), content)
      end

      # List all existing task names.
      def list_tasks
        return [] unless Dir.exist?(TASKS_DIR)

        Dir.glob(File.join(TASKS_DIR, "*.md")).map do |path|
          File.basename(path, ".md")
        end.sort
      end

      # Delete a task file and remove all schedules that reference it.
      # Returns true if the task file existed and was deleted, false otherwise.
      def delete_task(task_name)
        path = task_file_path(task_name)
        return false unless File.exist?(path)

        File.delete(path)
        # Remove all schedules referencing this task
        load_schedules.select { |s| s["task"] == task_name }.each do |s|
          remove_schedule(s["name"])
        end
        true
      end

      # Return the file path for a task.
      def task_file_path(task_name)
        File.join(TASKS_DIR, "#{task_name}.md")
      end

      # ── Internal ─────────────────────────────────────────────────────────────

      private def run_loop
        loop do
          break unless @running

          tick(Time.now)

          # Sleep until the start of the next minute
          now     = Time.now
          sleep_s = 60 - now.sec
          sleep(sleep_s)
        end
      rescue => e
        Clacky::Logger.error("scheduler_fatal_error", error: e)
      end

      # Check all enabled schedules against the given time and fire matching ones.
      private def tick(now)
        load_schedules.each do |schedule|
          next unless schedule["enabled"] != false
          next unless cron_matches?(schedule["cron"].to_s, now)

          fire_task(schedule)
        rescue => e
          Clacky::Logger.error("scheduler_tick_error", schedule: schedule["name"], error: e)
        end
      end

      # Execute a scheduled task by creating a new agent session.
      private def fire_task(schedule)
        task_name = schedule["task"].to_s
        prompt    = read_task(task_name)
        name      = "⏰ #{schedule["name"]} #{Time.now.strftime("%H:%M")}"

        working_dir = File.expand_path("~/clacky_workspace")
        FileUtils.mkdir_p(working_dir)

        # Scheduled tasks run unattended — use auto_approve so request_user_feedback doesn't block.
        session_id = @session_builder.call(name: name, working_dir: working_dir, permission_mode: :auto_approve, source: :cron)

        Clacky::Logger.info("scheduler_task_fired", task: task_name, session: session_id)

        # Run the agent in a background thread so the scheduler tick is non-blocking.
        Thread.new do
          session = @registry.get(session_id)
          agent   = nil
          @registry.with_session(session_id) { |s| agent = s[:agent] }
          next unless agent

          @registry.update(session_id, status: :running)
          agent.run(prompt)
          @registry.update(session_id, status: :idle)
          Clacky::Logger.info("scheduler_task_completed", task: task_name, session: session_id)
        rescue => e
          @registry.update(session_id, status: :error, error: e.message)
          Clacky::Logger.error("scheduler_task_failed", task: task_name, session: session_id, error: e)
        end

      rescue => e
        Clacky::Logger.error("scheduler_fire_error", task: schedule["task"], error: e)
      end

      # ── Cron parsing ─────────────────────────────────────────────────────────

      # Returns true if the 5-field cron expression matches the given Time.
      # Fields: minute hour day-of-month month day-of-week
      private def cron_matches?(expr, time)
        fields = expr.strip.split(/\s+/)
        return false unless fields.size == 5

        minute, hour, dom, month, dow = fields

        cron_field_matches?(minute, time.min)   &&
          cron_field_matches?(hour,   time.hour)  &&
          cron_field_matches?(dom,    time.day)   &&
          cron_field_matches?(month,  time.month) &&
          cron_field_matches?(dow,    time.wday)
      end

      # Match a single cron field value against the actual time value.
      # Supports: * (any), */n (step), n-m (range), n-m/s (range with step),
      #           and comma-separated lists of the above.
      private def cron_field_matches?(field, value)
        field.split(",").any? { |part| cron_part_matches?(part.strip, value) }
      end

      private def cron_part_matches?(part, value)
        if part == "*"
          true
        elsif part.include?("/")
          base, step = part.split("/")
          step = step.to_i
          return false if step.zero?

          if base == "*"
            (value % step).zero?
          else
            min, max = base.split("-").map(&:to_i)
            max ||= value
            value.between?(min, max) && ((value - min) % step).zero?
          end
        elsif part.include?("-")
          min, max = part.split("-").map(&:to_i)
          value.between?(min, max)
        else
          part.to_i == value
        end
      end

      # ── File I/O ─────────────────────────────────────────────────────────────

      private def load_schedules
        return [] unless File.exist?(SCHEDULES_FILE)

        data = YAMLCompat.load_file(SCHEDULES_FILE, permitted_classes: [Symbol])
        Array(data)
      rescue => e
        Clacky::Logger.error("scheduler_load_schedules_error", error: e)
        []
      end

      private def save_schedules(list)
        FileUtils.mkdir_p(File.dirname(SCHEDULES_FILE))
        File.write(SCHEDULES_FILE, YAML.dump(list))
      end
    end
  end
end
