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

    # ── Chunk file I/O (for conversation compression archives) ────────────────
    #
    # The SessionManager is the single owner of sessions/{base}-chunk-N.md
    # file naming, writing, discovery, and deletion. Everything else in the
    # codebase (MessageCompressorHelper, SessionSerializer) should go through
    # these methods rather than building paths or scanning the directory
    # directly — this keeps the on-disk layout under one roof and makes it
    # easy to evolve (e.g. add encryption, switch to a DB).

    # Discover all chunk MD files on disk for a given session.
    # Returns them sorted by chunk index ascending (oldest first).
    #
    # @param session_id [String] full session id (or at least first 8 chars)
    # @param created_at [String] ISO-8601 timestamp used in the base filename
    # @return [Array<Hash>] each with :index, :path, :basename, :topics
    def chunks_for_current(session_id, created_at)
      return [] unless session_id && created_at

      base = chunk_base_name(session_id, created_at)
      pattern = File.join(@sessions_dir, "#{base}-chunk-*.md")

      Dir.glob(pattern).filter_map do |path|
        basename = File.basename(path)
        # Extract integer index from "<base>-chunk-<N>.md"
        m = basename.match(/-chunk-(\d+)\.md\z/)
        next nil unless m

        {
          index: m[1].to_i,
          path: path,
          basename: basename,
          topics: read_chunk_topics(path)
        }
      end.sort_by { |c| c[:index] }
    end

    # Next unused chunk index for a session, derived from disk.
    # This is the ONLY correct way to compute the next chunk index —
    # counting compressed_summary messages in history caps at 1 after the
    # second compression (rebuild keeps only the latest summary) and
    # in-memory counters reset on process restart.
    def next_chunk_index(session_id, created_at)
      existing = chunks_for_current(session_id, created_at)
      (existing.map { |c| c[:index] }.max || 0) + 1
    end

    # Write a chunk MD file to disk. Returns the absolute path.
    # Caller is responsible for generating the MD content — this method
    # only handles filesystem concerns (path assembly, write, chmod).
    def write_chunk(session_id, created_at, chunk_index, md_content)
      return nil unless session_id && created_at

      base = chunk_base_name(session_id, created_at)
      chunk_path = File.join(@sessions_dir, "#{base}-chunk-#{chunk_index}.md")

      File.write(chunk_path, md_content)
      FileUtils.chmod(0o600, chunk_path)

      chunk_path
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
      "#{chunk_base_name(session_id, created_at)}.json"
    end

    # Base name (without extension) shared by a session's .json file and its
    # chunk-N.md archive files. Kept as a single source of truth so chunk
    # I/O stays consistent with the session filename.
    private def chunk_base_name(session_id, created_at)
      datetime = Time.parse(created_at).strftime("%Y-%m-%d-%H-%M-%S")
      short_id = session_id[0..7]
      "#{datetime}-#{short_id}"
    end

    # Read the `topics:` field from a chunk MD file's YAML-like front matter.
    # Only scans the first ~20 lines — front matter is tiny and we don't
    # want to read megabytes of archived conversation just to grab one line.
    # Returns nil if the file is missing, unreadable, or has no topics.
    private def read_chunk_topics(path)
      return nil unless File.exist?(path)

      lines = []
      File.open(path, "r") do |f|
        20.times do
          line = f.gets
          break if line.nil?
          lines << line
        end
      end

      in_front_matter = false
      lines.each do |line|
        stripped = line.strip
        if stripped == "---"
          break if in_front_matter
          in_front_matter = true
          next
        end
        next unless in_front_matter

        if (m = stripped.match(/\Atopics:\s*(.+)\z/))
          topics = m[1].strip
          return topics.empty? ? nil : topics
        end
      end
      nil
    rescue
      nil
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
