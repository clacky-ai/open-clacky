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

    # Save a session. Returns the file path.
    def save(session_data)
      filename = generate_filename(session_data[:session_id], session_data[:created_at])
      filepath = File.join(@sessions_dir, filename)

      File.write(filepath, JSON.pretty_generate(session_data))
      FileUtils.chmod(0o600, filepath)

      @last_saved_path = filepath

      # Keep only the most recent 200 sessions (best-effort, never block save)
      begin
        cleanup_by_count(keep: 200)
      rescue Exception # rubocop:disable Lint/RescueException
        # Cleanup is non-critical; swallow all errors (including AgentInterrupted)
      end

      filepath
    end

    # Path of the last saved session file.
    def last_saved_path
      @last_saved_path
    end

    # Load a specific session by ID. Returns nil if not found.
    def load(session_id)
      all_sessions.find { |s| s[:session_id].to_s.start_with?(session_id.to_s) }
    end

    # Physical delete — removes disk file + associated chunk files.
    # Returns true if found and deleted, false if not found.
    def delete(session_id)
      session = all_sessions.find { |s| s[:session_id].to_s.start_with?(session_id.to_s) }
      return false unless session

      filepath = File.join(@sessions_dir, generate_filename(session[:session_id], session[:created_at]))
      delete_session_with_chunks(filepath)
      true
    end

    # Return the on-disk files associated with a session: the main JSON file
    # and any "{base}-chunk-*.md" archive files. Used by the export / download
    # endpoint so the UI can bundle everything a user may need for debugging.
    # Returns nil if the session is not found, or a Hash:
    #   {
    #     session:   Hash,        # the loaded session metadata
    #     json_path: String,      # absolute path to session.json
    #     chunks:    [String]     # sorted absolute paths to chunk *.md files
    #   }
    def files_for(session_id)
      session = all_sessions.find { |s| s[:session_id].to_s.start_with?(session_id.to_s) }
      return nil unless session

      json_path = File.join(@sessions_dir, generate_filename(session[:session_id], session[:created_at]))
      return nil unless File.exist?(json_path)

      base   = File.basename(json_path, ".json")
      chunks = Dir.glob(File.join(@sessions_dir, "#{base}-chunk-*.md")).sort

      { session: session, json_path: json_path, chunks: chunks }
    end

    # All sessions from disk, newest-first (sorted by created_at).
    # Optional filters:
    #   current_dir: (String) if given, sessions matching working_dir come first
    #   limit:       (Integer) max number of sessions to return
    def all_sessions(current_dir: nil, limit: nil)
      sessions = Dir.glob(File.join(@sessions_dir, "*.json")).filter_map do |filepath|
        load_session_file(filepath)
      end.sort_by { |s| s[:created_at] || "" }.reverse

      if current_dir
        current_sessions = sessions.select { |s| s[:working_dir] == current_dir }
        other_sessions   = sessions.reject { |s| s[:working_dir] == current_dir }
        sessions = current_sessions + other_sessions
      end

      limit ? sessions.first(limit) : sessions
    end

    # Return the most recent session for a given working directory, or nil.
    def latest_for_directory(working_dir)
      all_sessions(current_dir: working_dir).first
    end

    # Delete sessions not accessed within the given number of days (default: 90).
    # Returns count of deleted sessions.
    def cleanup(days: 90)
      cutoff = Time.now - (days * 24 * 60 * 60)
      deleted = 0
      Dir.glob(File.join(@sessions_dir, "*.json")).each do |filepath|
        session = load_session_file(filepath)
        next unless session
        if Time.parse(session[:updated_at]) < cutoff
          delete_session_with_chunks(filepath)
          deleted += 1
        end
      end
      deleted
    end

    # Keep only the most recent N sessions by created_at; delete the rest.
    # Returns count of deleted sessions.
    def cleanup_by_count(keep:)
      sessions = all_sessions # already sorted newest-first
      return 0 if sessions.size <= keep

      sessions[keep..].each do |session|
        filepath = File.join(@sessions_dir, generate_filename(session[:session_id], session[:created_at]))
        delete_session_with_chunks(filepath) if File.exist?(filepath)
      end.size
    end


    def ensure_sessions_dir
      FileUtils.mkdir_p(@sessions_dir) unless Dir.exist?(@sessions_dir)
    end

    def generate_filename(session_id, created_at)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      "#{datetime}-#{short_id}.json"
    end

    # Delete a session JSON file and all its associated chunk MD files.
    def delete_session_with_chunks(json_filepath)
      File.delete(json_filepath) if File.exist?(json_filepath)
      base = File.basename(json_filepath, ".json")
      Dir.glob(File.join(@sessions_dir, "#{base}-chunk-*.md")).each { |f| File.delete(f) }
    end

    def load_session_file(filepath)
      JSON.parse(File.read(filepath), symbolize_names: true)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end
  end
end
