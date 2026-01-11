# frozen_string_literal: true

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
  spec.executables = ["clacky", "openclacky"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "tty-spinner", "~> 0.9"
  spec.add_dependency "diffy", "~> 3.4"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
