# frozen_string_literal: true

# Friendly Ruby version check — must come before anything else so it triggers
# during `gem install` when the gemspec is evaluated.
if RUBY_VERSION < "3.1.0"
  abort <<~MSG

    ✗  Ruby #{RUBY_VERSION} is not supported.

    OpenClacky requires Ruby >= 3.1.0, but your system is running Ruby #{RUBY_VERSION}.

    ──────────────────────────────────────────────────────────────────────
     Recommended: Use the one-line installer (handles Ruby automatically)
    ──────────────────────────────────────────────────────────────────────

      /bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/open-clacky/main/scripts/install.sh)"

    This script will automatically install the correct Ruby version via mise
    and then install OpenClacky — no manual Ruby upgrade needed.

    For more details, visit:
      https://github.com/clacky-ai/open-clacky#installation

  MSG
end

require_relative "lib/clacky/version"

Gem::Specification.new do |spec|
  spec.name = "openclacky"
  spec.version = Clacky::VERSION
  spec.authors = ["windy"]
  spec.email = ["yafei@dao42.com"]

  spec.summary = "A command-line interface for AI models (Claude, OpenAI, etc.)"
  spec.description = "OpenClacky is a Ruby CLI tool for interacting with AI models via OpenAI-compatible APIs. It provides chat functionality and autonomous AI agent capabilities with tool use."
  spec.homepage = "https://github.com/yafeilee/clacky"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/yafeilee/clacky"
  spec.metadata["changelog_uri"] = "https://github.com/yafeilee/clacky/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "bin"
  spec.executables = ["clacky", "openclacky", "clarky"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "tty-spinner", "~> 0.9"
  spec.add_dependency "diffy", "~> 3.4"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-screen", "~> 0.8"
  spec.add_dependency "tty-markdown", "~> 0.7"
  spec.add_dependency "base64", "~> 0.3.0"
  spec.add_dependency "websocket-driver", "~> 0.7"
  spec.add_dependency "webrick", "~> 1.8"
  spec.add_dependency "artii", "~> 2.1"
  spec.add_dependency "rubyzip", "~> 3.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
