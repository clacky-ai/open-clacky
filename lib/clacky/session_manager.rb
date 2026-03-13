# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Clacky
  class SessionManager
    SESSIONS_DIR = File.join(Dir.home, ".clacky", "sessions")

    # Generate a new unique session ID (16-char hex string).
    # This is the single authoritative source for session IDs — all components
    # (Agent, SessionRegistry) should receive an ID generated here rather than
    # creating their own.
    def self.generate_id
      SecureRandom.hex(8)
    end

    def initialize(sessions_dir: nil)
      @sessions_dir = sessions_dir || SESSIONS_DIR
      ensure_sessions_dir
    end

    # Save a session
    def save(session_data)
      filename = generate_filename(session_data[:session_id], session_data[:created_at])
      filepath = File.join(@sessions_dir, filename)

      File.write(filepath, JSON.pretty_generate(session_data))
      FileUtils.chmod(0o600, filepath)

      @last_saved_path = filepath

      # Keep only the most recent 10 sessions
      cleanup_by_count(keep: 10)

      filepath
    end

    # Get the path of the last saved session
    def last_saved_path
      @last_saved_path
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

    # Get the most recent N sessions for a specific working directory
    def latest_n_for_directory(working_dir, n = 5)
      all_sessions
        .select { |s| s[:working_dir] == working_dir }
        .sort_by { |s| Time.parse(s[:updated_at]) }
        .reverse
        .first(n)
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

      Dir.glob(File.join(@sessions_dir, "*.json")).each do |filepath|
        session = load_session_file(filepath)
        next unless session

        updated_at = Time.parse(session[:updated_at])
        if updated_at < cutoff_time
          delete_session_with_chunks(filepath)
          deleted_count += 1
        end
      end

      deleted_count
    end

    # Keep only the most recent N sessions, delete older ones
    def cleanup_by_count(keep:)
      sessions = all_sessions.sort_by { |s| Time.parse(s[:updated_at]) }.reverse

      return 0 if sessions.size <= keep

      sessions_to_delete = sessions[keep..]
      deleted_count = 0

      sessions_to_delete.each do |session|
        filename = generate_filename(session[:session_id], session[:created_at])
        filepath = File.join(@sessions_dir, filename)

        if File.exist?(filepath)
          delete_session_with_chunks(filepath)
          deleted_count += 1
        end
      end

      deleted_count
    end

    private

    def ensure_sessions_dir
      FileUtils.mkdir_p(@sessions_dir) unless Dir.exist?(@sessions_dir)
    end

    def generate_filename(session_id, created_at)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      "#{datetime}-#{short_id}.json"
    end

    # Delete a session JSON file and all its associated chunk MD files
    # Chunk files follow the pattern: {base}-chunk-{n}.md
    def delete_session_with_chunks(json_filepath)
      # Delete the main session JSON
      File.delete(json_filepath) if File.exist?(json_filepath)

      # Find and delete associated chunk MD files
      base = File.basename(json_filepath, ".json")
      chunk_pattern = File.join(@sessions_dir, "#{base}-chunk-*.md")
      Dir.glob(chunk_pattern).each do |chunk_file|
        File.delete(chunk_file)
      end
    end

    def all_sessions
      Dir.glob(File.join(@sessions_dir, "*.json")).map do |filepath|
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
