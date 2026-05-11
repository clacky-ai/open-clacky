#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark runner for system prompt A/B testing
# Usage: ruby benchmark/runner.rb

require "fileutils"
require "json"
require "tmpdir"

project_root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(project_root, "lib")
require "clacky"

class BenchmarkRunner
  PROMPT_FILES = {
    base: "lib/clacky/default_agents/base_prompt.md",
    coding: "lib/clacky/default_agents/coding/system_prompt.md",
    general: "lib/clacky/default_agents/general/system_prompt.md"
  }.freeze

  FIXTURE_DIR = File.expand_path("fixtures/sample_project", __dir__)
  RESULTS_DIR = File.expand_path("results", __dir__)

  TASKS = [
    {
      name: "simple_edit",
      description: "Rename methods to snake_case across files",
      prompt: "Rename the method `calculateTotal` to `calculate_total` in all files. Also rename `calculateTotalWithTax` to `calculate_total_with_tax` and `applyDiscount` to `apply_discount`. Update all references and the test file too.",
      agent_profile: "coding"
    },
    {
      name: "feature_addition",
      description: "Add a new /products API endpoint with tests",
      prompt: "Add a new `/products` endpoint to the ApiHandler that returns products from the store with optional pagination via `page` and `per_page` params. Also create a test file `spec/api_handler_spec.rb` with basic tests for this endpoint.",
      agent_profile: "coding"
    },
    {
      name: "refactoring",
      description: "Extract helper method from duplicated pattern",
      prompt: "In order_calculator.rb, both `calculate_total_with_tax` and `apply_discount` call `calculate_total` as their first step. Refactor to eliminate this duplication in the cleanest way possible. Do not over-engineer.",
      agent_profile: "coding"
    },
    {
      name: "bug_fix",
      description: "Fix XSS vulnerability in HTML rendering",
      prompt: "Fix the XSS vulnerability in user_renderer.rb. The methods directly interpolate user input into HTML without escaping. Make the rendering safe against XSS attacks.",
      agent_profile: "coding"
    },
    {
      name: "git_workflow",
      description: "Fix bug and stage changes safely with git",
      prompt: "Fix the XSS vulnerability in user_renderer.rb, then use git to stage only the changed file for commit. Do NOT stage all files.",
      agent_profile: "coding"
    }
  ].freeze

  def initialize
    @project_root = File.expand_path("..", __dir__)
    @original_prompts = read_current_prompts
    FileUtils.mkdir_p(RESULTS_DIR)
  end

  def run
    run_baseline
    run_treatment
    run_report
  end

  def run_baseline
    puts "=" * 70
    puts "OpenClacky System Prompt Benchmark - BASELINE"
    puts "=" * 70
    puts "Project: #{@project_root}"
    puts "Model: #{agent_config.model_name}"
    puts "Tasks: #{TASKS.length}"
    puts

    unless git_clean?
      puts "WARNING: Prompt files have uncommitted changes. Baseline may not reflect main."
      puts
    end

    baseline_prompts = read_baseline_prompts
    write_prompts(baseline_prompts)
    results = run_all_tasks(:baseline)
    write_results("baseline", results)

    # Restore treatment prompts
    write_prompts(@original_prompts)
    puts "\nBaseline complete. Results saved."
    results
  rescue => e
    write_prompts(@original_prompts)
    raise
  end

  def run_treatment
    puts "=" * 70
    puts "OpenClacky System Prompt Benchmark - TREATMENT"
    puts "=" * 70
    puts "Project: #{@project_root}"
    puts "Model: #{agent_config.model_name}"
    puts "Tasks: #{TASKS.length}"
    puts

    # Ensure treatment prompts are active
    write_prompts(@original_prompts)
    results = run_all_tasks(:treatment)
    write_results("treatment", results)

    puts "\nTreatment complete. Results saved."
    results
  end

  def run_report
    baseline_file = Dir.glob(File.join(RESULTS_DIR, "baseline_*.json")).max
    treatment_file = Dir.glob(File.join(RESULTS_DIR, "treatment_*.json")).max

    unless baseline_file
      puts "ERROR: No baseline results found in #{RESULTS_DIR}"
      exit 1
    end
    unless treatment_file
      puts "ERROR: No treatment results found in #{RESULTS_DIR}"
      exit 1
    end

    baseline = JSON.parse(File.read(baseline_file), symbolize_names: true)
    treatment = JSON.parse(File.read(treatment_file), symbolize_names: true)

    puts "=" * 70
    puts "COMPARISON REPORT"
    puts "=" * 70
    puts "Baseline: #{File.basename(baseline_file)}"
    puts "Treatment: #{File.basename(treatment_file)}"
    puts
    compare_and_print(baseline, treatment)

    # Save combined report
    report_path = File.join(RESULTS_DIR, "report_#{timestamp}.json")
    File.write(report_path, JSON.pretty_generate({
      baseline: baseline,
      treatment: treatment,
      meta: {
        model: agent_config.model_name,
        timestamp: Time.now.iso8601,
        tasks: TASKS.map { |t| t[:name] }
      }
    }))
    puts
    puts "Full report saved to: #{report_path}"
  end

  private

  def agent_config
    @agent_config ||= Clacky::AgentConfig.load
  end

  def read_current_prompts
    prompts = {}
    PROMPT_FILES.each do |key, rel_path|
      full_path = File.join(@project_root, rel_path)
      prompts[key] = File.read(full_path)
    end
    prompts
  end

  def read_baseline_prompts
    prompts = {}
    PROMPT_FILES.each do |key, rel_path|
      content = `git -C "#{@project_root}" show main:"#{rel_path}" 2>/dev/null`
      if $?.success? && !content.empty?
        prompts[key] = content
      else
        puts "  Warning: Could not read #{rel_path} from main, using current"
        prompts[key] = @original_prompts[key]
      end
    end
    prompts
  end

  def write_prompts(prompts)
    prompts.each do |key, content|
      rel_path = PROMPT_FILES[key]
      full_path = File.join(@project_root, rel_path)
      File.write(full_path, content)
    end
  end

  def git_clean?
    PROMPT_FILES.values.all? do |rel_path|
      status = `git -C "#{@project_root}" status --porcelain "#{rel_path}" 2>/dev/null`
      status.strip.empty?
    end
  end

  def run_all_tasks(variant)
    results = {}
    TASKS.each_with_index do |task, idx|
      puts
      puts "[#{idx + 1}/#{TASKS.length}] #{task[:name]}: #{task[:description]}"
      results[task[:name]] = run_task(task, variant)
    end
    results
  end

  def run_task(task, variant)
    tmp_dir = File.join(Dir.tmpdir, "clacky_benchmark_#{variant}_#{task[:name]}_#{Process.pid}_#{Time.now.to_i}")
    FileUtils.cp_r(FIXTURE_DIR, tmp_dir)

    # Ensure tmp_dir is a git repo (cp_r preserves .git)
    Dir.chdir(tmp_dir) do
      system("git config user.email 'benchmark@test.com' >/dev/null 2>&1")
      system("git config user.name 'Benchmark' >/dev/null 2>&1")
    end

    config = agent_config.dup
    config.permission_mode = :auto_approve

    client = Clacky::Client.new(
      config.api_key,
      base_url: config.base_url,
      model: config.model_name,
      anthropic_format: config.anthropic_format?
    )

    agent = Clacky::Agent.new(
      client, config,
      working_dir: tmp_dir,
      ui: BenchmarkUI.new,
      profile: task[:agent_profile],
      session_id: Clacky::SessionManager.generate_id,
      source: :manual
    )

    start_time = Time.now
    agent.run(task[:prompt])
    duration = Time.now - start_time

    # Collect metrics
    metrics = {
      success: true,
      iterations: agent.iterations,
      total_cost: agent.total_cost.round(6),
      cost_source: agent.cost_source.to_s,
      duration_seconds: duration.round(2),
      cache_creation_input_tokens: agent.cache_stats[:cache_creation_input_tokens],
      cache_read_input_tokens: agent.cache_stats[:cache_read_input_tokens],
      total_requests: agent.cache_stats[:total_requests],
      cache_hit_requests: agent.cache_stats[:cache_hit_requests]
    }

    # Collect file changes
    metrics[:file_changes] = collect_file_changes(tmp_dir)

    # Collect assistant output for qualitative analysis
    metrics[:assistant_messages] = agent.history.to_a
      .select { |m| m[:role] == "assistant" }
      .map { |m| extract_text(m[:content]) }
      .compact

    metrics[:total_assistant_chars] = metrics[:assistant_messages].join.length

    # Cleanup
    FileUtils.rm_rf(tmp_dir)

    print_metrics(metrics)
    metrics
  rescue => e
    FileUtils.rm_rf(tmp_dir) if defined?(tmp_dir) && tmp_dir
    error_result = {
      success: false,
      error: e.message,
      error_class: e.class.name,
      iterations: defined?(agent) ? agent&.iterations : 0,
      total_cost: defined?(agent) ? agent&.total_cost&.round(6) : 0
    }
    puts "  ERROR: #{e.message}"
    error_result
  end

  def collect_file_changes(dir)
    changes = {}
    Dir.chdir(dir) do
      # Get list of modified files
      modified = `git diff --name-only 2>/dev/null`.strip.split("\n").reject(&:empty?)
      modified.each do |f|
        next unless File.exist?(f)
        changes[f] = File.read(f)
      end
    end
    changes
  end

  def extract_text(content)
    case content
    when String then content
    when Array
      text_parts = content.select { |p| p.is_a?(Hash) && p[:type] == "text" }
      text_parts.map { |p| p[:text] }.join(" ")
    else
      nil
    end
  end

  def print_metrics(metrics)
    if metrics[:success]
      puts "  Iterations: #{metrics[:iterations]} | Cost: $#{metrics[:total_cost]} | Duration: #{metrics[:duration_seconds]}s"
      puts "  Cache: write=#{metrics[:cache_creation_input_tokens]} read=#{metrics[:cache_read_input_tokens]}"
      puts "  Assistant chars: #{metrics[:total_assistant_chars]}"
      puts "  Files changed: #{metrics[:file_changes]&.keys&.join(', ') || 'none'}"
    else
      puts "  FAILED: #{metrics[:error]}"
    end
  end

  def write_results(name, results)
    path = File.join(RESULTS_DIR, "#{name}_#{timestamp}.json")
    File.write(path, JSON.pretty_generate(results))
    puts "\n#{name.capitalize} results saved to: #{path}"
  end

  def timestamp
    @timestamp ||= Time.now.strftime("%Y%m%d_%H%M%S")
  end

  def compare_and_print(baseline, treatment)
    puts
    printf "%-20s %12s %12s %12s\n", "Task", "Baseline", "Treatment", "Delta"
    puts "-" * 60

    TASKS.each do |task|
      task_key = task[:name].to_sym
      b = baseline[task_key] || {}
      t = treatment[task_key] || {}

      next unless b[:success] && t[:success]

      b_cost = b[:total_cost] || 0
      t_cost = t[:total_cost] || 0
      cost_delta = b_cost > 0 ? "#{(t_cost / b_cost * 100).round(1)}%" : "N/A"

      b_iter = b[:iterations] || 0
      t_iter = t[:iterations] || 0

      b_chars = b[:total_assistant_chars] || 0
      t_chars = t[:total_assistant_chars] || 0
      chars_delta = b_chars > 0 ? "#{(t_chars / b_chars.to_f * 100).round(1)}%" : "N/A"

      printf "%-20s\n", task[:name]
      printf "  Cost:              $%-10.6f $%-10.6f %s\n", b_cost, t_cost, cost_delta
      printf "  Iterations:        %-11d %-11d %s\n", b_iter, t_iter, "#{t_iter - b_iter > 0 ? '+' : ''}#{t_iter - b_iter}"
      printf "  Assistant chars:   %-11d %-11d %s\n", b_chars, t_chars, chars_delta
      puts
    end

    # Totals
    b_total_cost = 0
    t_total_cost = 0
    b_total_iter = 0
    t_total_iter = 0
    b_total_chars = 0
    t_total_chars = 0

    TASKS.each do |task|
      task_key = task[:name].to_sym
      b = baseline[task_key] || {}
      t = treatment[task_key] || {}
      next unless b[:success] && t[:success]

      b_total_cost += b[:total_cost] || 0
      t_total_cost += t[:total_cost] || 0
      b_total_iter += b[:iterations] || 0
      t_total_iter += t[:iterations] || 0
      b_total_chars += b[:total_assistant_chars] || 0
      t_total_chars += t[:total_assistant_chars] || 0
    end

    puts "-" * 60
    printf "%-20s\n", "TOTALS"
    cost_pct = b_total_cost > 0 ? (t_total_cost / b_total_cost * 100).round(1) : 0
    printf "  Total cost:        $%-10.6f $%-10.6f %s%%\n", b_total_cost, t_total_cost, cost_pct
    printf "  Total iterations:  %-11d %-11d %+d\n", b_total_iter, t_total_iter, t_total_iter - b_total_iter
    chars_pct = b_total_chars > 0 ? (t_total_chars / b_total_chars.to_f * 100).round(1) : 0
    printf "  Total chars:       %-11d %-11d %s%%\n", b_total_chars, t_total_chars, chars_pct
  end

  # Minimal UI that captures output without displaying
  class BenchmarkUI
    def log(msg, level: :info); end
    def show_assistant_message(content, files: []); end
    def show_tool_call(name, args); end
    def show_tool_result(result); end
    def show_tool_stdout(lines); end
    def show_tool_error(error); end
    def show_tool_args(formatted_args); end
    def show_file_write_preview(path, is_new_file:); end
    def show_file_edit_preview(path); end
    def show_file_error(error_message); end
    def show_shell_preview(command); end
    def show_diff(old_content, new_content, max_lines: 50); end
    def show_token_usage(token_data); end
    def show_complete(iterations:, cost:, duration: nil, cache_stats: nil, awaiting_user_feedback: false, cost_source: nil); end
    def append_output(content); end
    def show_info(message, prefix_newline: true); end
    def show_warning(message); end
    def show_error(message); end
    def show_success(message); end
    def show_progress(message = nil, prefix_newline: true, progress_type: "thinking", phase: "active", metadata: {}); end
    def start_progress(message: nil, style: :primary, quiet_on_fast_finish: false); end
    def with_progress(message: nil, style: :primary, quiet_on_fast_finish: false)
      yield if block_given?
    end
    def update_sessionbar(tasks: nil, cost: nil, cost_source: nil, status: nil, latency: nil); end
    def update_todos(todos); end
    def set_working_status; end
    def set_idle_status; end
    def request_confirmation(message, default: true); end
    def clear_input; end
    def set_input_tips(message, type: :info); end
    def stop; end
  end
end

if __FILE__ == $0
  variant = ARGV[0]&.downcase
  runner = BenchmarkRunner.new

  case variant
  when "baseline"
    runner.run_baseline
  when "treatment"
    runner.run_treatment
  when "report"
    runner.run_report
  else
    runner.run
  end
end
