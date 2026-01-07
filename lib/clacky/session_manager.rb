# frozen_string_literal: true

require "json"
require "fileutils"

module Clacky
  class SessionManager
    SESSIONS_DIR = File.join(Dir.home, ".clacky", "sessions")

    def initialize
      ensure_sessions_dir
    end

    # Save a session
    def save(session_data)
      filename = generate_filename(session_data[:session_id], session_data[:created_at])
      filepath = File.join(SESSIONS_DIR, filename)

      File.write(filepath, JSON.pretty_generate(session_data))
      FileUtils.chmod(0o600, filepath)

      filepath
    end

    # Load a specific session by ID
    def load(session_id)
      sessions = all_sessions
      session = sessions.find { |s| s[:session_id].start_with?(session_id) }
      session
    end

    # Get the most recent session for a specific working directory
    def latest_for_directory(working_dir)
      sessions = all_sessions
      sessions
        .select { |s| s[:working_dir] == working_dir }
        .max_by { |s| Time.parse(s[:updated_at]) }
    end

    # List recent sessions, prioritizing those from current directory
    def list(current_dir: nil, limit: 5)
      sessions = all_sessions.sort_by { |s| Time.parse(s[:updated_at]) }.reverse

      if current_dir
        current_sessions = sessions.select { |s| s[:working_dir] == current_dir }
        other_sessions = sessions.reject { |s| s[:working_dir] == current_dir }
        (current_sessions + other_sessions).first(limit)
      else
        sessions.first(limit)
      end
    end

    # Delete old sessions (older than days)
    def cleanup(days: 30)
      cutoff_time = Time.now - (days * 24 * 60 * 60)
      deleted_count = 0

      Dir.glob(File.join(SESSIONS_DIR, "*.json")).each do |filepath|
        session = load_session_file(filepath)
        next unless session

        updated_at = Time.parse(session[:updated_at])
        if updated_at < cutoff_time
          File.delete(filepath)
          deleted_count += 1
        end
      end

      deleted_count
    end

    private

    def ensure_sessions_dir
      FileUtils.mkdir_p(SESSIONS_DIR) unless Dir.exist?(SESSIONS_DIR)
    end

    def generate_filename(session_id, created_at)
      date = Time.parse(created_at).strftime("%Y-%m-%d")
      short_id = session_id[0..7]
      "#{date}_#{short_id}.json"
    end

    def all_sessions
      Dir.glob(File.join(SESSIONS_DIR, "*.json")).map do |filepath|
        load_session_file(filepath)
      end.compact
    end

    def load_session_file(filepath)
      JSON.parse(File.read(filepath), symbolize_names: true)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end
  end
end
