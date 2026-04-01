# frozen_string_literal: true

require "fileutils"

module Clacky
  module Utils
    # Manages user-space shell scripts in ~/.clacky/scripts/.
    #
    # On first use, bundled scripts are copied from the gem's scripts/
    # directory into ~/.clacky/scripts/. The user-space copy is always
    # used so users can customise scripts without modifying the gem.
    #
    # Bundled scripts are re-copied when the gem is upgraded (detected
    # via gem version stamp in ~/.clacky/scripts/.version).
    module ScriptsManager
      SCRIPTS_DIR         = File.expand_path("~/.clacky/scripts").freeze
      DEFAULT_SCRIPTS_DIR = File.expand_path("../../../../scripts", __dir__).freeze
      VERSION_FILE        = File.join(SCRIPTS_DIR, ".version").freeze

      SCRIPTS = %w[
        install_browser.sh
      ].freeze

      # Copy bundled scripts to ~/.clacky/scripts/ if missing or outdated.
      # Called once at agent startup — fast (no-op after first run).
      def self.setup!
        FileUtils.mkdir_p(SCRIPTS_DIR)

        current_version = Clacky::VERSION
        stored_version  = File.exist?(VERSION_FILE) ? File.read(VERSION_FILE).strip : nil

        SCRIPTS.each do |script|
          dest = File.join(SCRIPTS_DIR, script)
          src  = File.join(DEFAULT_SCRIPTS_DIR, script)
          next unless File.exist?(src)

          # Copy if missing or gem was upgraded
          if !File.exist?(dest) || stored_version != current_version
            FileUtils.cp(src, dest)
            FileUtils.chmod(0o755, dest)
          end
        end

        # Write version stamp after successful copy
        File.write(VERSION_FILE, current_version)
      end

      # Returns the full path to a managed script.
      # @param name [String] script filename, e.g. "install_browser.sh"
      # @return [String, nil]
      def self.path_for(name)
        dest = File.join(SCRIPTS_DIR, name)
        File.exist?(dest) ? dest : nil
      end
    end
  end
end
