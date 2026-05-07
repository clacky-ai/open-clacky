#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'uri'
require 'net/http'
require 'find'

# Install a skill from a remote zip archive URL.
# Usage: ruby install_from_zip.rb <zip_url>
#
# The zip archive is expected to contain a skill directory at its root, e.g.:
#   my-skill/
#     SKILL.md
#     scripts/
#
# Or the archive may contain multiple skill directories (each with a SKILL.md).
class ZipSkillInstaller
  ZIP_URL_PATTERN = %r{^https?://.+\.zip(\?.*)?$}i

  def initialize(zip_source, skill_name: nil, target_dir: nil, skip_if_exists: false)
    @zip_source = zip_source
    @local_path = local_zip_path?(zip_source)
    # skill_name can be provided explicitly (e.g. slug from the store API).
    # If not provided, we try to infer it from the filename in the URL/path, e.g.
    # "ui-ux-pro-max-1.0.0.zip" → "ui-ux-pro-max".
    @skill_name = skill_name || infer_skill_name(zip_source)
    @target_dir = target_dir || File.join(Dir.home, '.clacky', 'skills')
    # When true, existing skill directories are preserved and the install for
    # that specific skill is skipped (recorded in @skipped_skills).
    # Default false keeps the legacy "overwrite" behaviour for `install`.
    @skip_if_exists   = skip_if_exists
    # Suppresses user-facing puts for programmatic callers (set by `perform`).
    @silent           = false
    @installed_skills = []
    @skipped_skills   = []
    @errors           = []
  end

  # Programmatic entry point for library-style callers (e.g. onboard pre-install).
  #
  # Unlike `install`, this method:
  #   - does NOT print user-facing output
  #   - does NOT call `exit` on failure (raises instead)
  #   - returns a result hash: { installed: [...], skipped: [...], errors: [...] }
  #
  # The caller is responsible for rendering feedback and deciding whether any
  # error is fatal.
  def perform
    @silent = true
    do_install
    { installed: @installed_skills, skipped: @skipped_skills, errors: @errors }
  end

  # Main installation entry point (CLI). Prints progress, prints a final
  # report, and calls `exit` on failure. Use `perform` for programmatic use.
  def install
    do_install
    report_results
  rescue ArgumentError => e
    puts "Error: #{e.message}"
    exit 1
  rescue StandardError => e
    puts "Error: Installation failed: #{e.message}"
    exit 1
  end

  # Shared core used by both `install` (CLI) and `perform` (library).
  # Raises on invalid input; the caller decides how to surface errors.
  private def do_install
    if @local_path
      # Install directly from a local zip file — no download needed.
      # Expand tilde in path (e.g. ~/Downloads/skill.zip).
      expanded = File.expand_path(@zip_source)
      raise ArgumentError, "File not found: #{@zip_source}"  unless File.exist?(expanded)
      raise ArgumentError, "Not a zip file: #{@zip_source}"  unless expanded.end_with?('.zip')

      Dir.mktmpdir('clacky-zip-') do |tmpdir|
        extract_zip(expanded, tmpdir)
        discover_and_install_skills(File.join(tmpdir, 'extracted'))
      end
    else
      # Install from a remote URL.
      unless valid_zip_url?
        raise ArgumentError, "Invalid zip source: #{@zip_source}\n" \
                             "Provide an http(s) URL ending with .zip, or an absolute path to a local zip file."
      end

      Dir.mktmpdir('clacky-zip-') do |tmpdir|
        zip_path = download_zip(tmpdir)
        extract_zip(zip_path, tmpdir)
        discover_and_install_skills(File.join(tmpdir, 'extracted'))
      end
    end
  end

  # Return true if the source looks like a local file path (absolute or relative ending in .zip).
  private def local_zip_path?(source)
    source.start_with?('/') || source.start_with?('~') || source.start_with?('./') ||
      (source.end_with?('.zip') && !source.start_with?('http'))
  end

  # Infer a skill name from the zip filename, stripping version suffixes.
  # Works for both URLs and local paths.
  # e.g. "ui-ux-pro-max-1.0.0.zip" → "ui-ux-pro-max"
  private def infer_skill_name(source)
    filename = if source.start_with?('http')
                 File.basename(URI.parse(source).path, '.zip') rescue File.basename(source, '.zip')
               else
                 File.basename(source, '.zip')
               end
    # Strip trailing version segment like "-1.0.0" or "-2.3"
    filename.sub(/-\d+(\.\d+)+$/, '')
  end

  private def valid_zip_url?
    @zip_source.match?(ZIP_URL_PATTERN)
  end

  # Download the zip file to tmpdir and return its local path.
  private def download_zip(tmpdir)
    unless @silent
      puts "Downloading skill package..."
      puts "   #{@zip_source}"
    end

    zip_path = File.join(tmpdir, 'skill.zip')
    uri = URI.parse(@zip_source)

    # Follow redirects up to 5 times (ActiveStorage often redirects).
    max_redirects = 5
    current_uri = uri

    max_redirects.times do
      Net::HTTP.start(current_uri.host, current_uri.port,
                      use_ssl: current_uri.scheme == 'https',
                      open_timeout: 15, read_timeout: 60) do |http|
        request = Net::HTTP::Get.new(current_uri.request_uri)
        http.request(request) do |response|
          case response.code.to_i
          when 200
            File.open(zip_path, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
            return zip_path
          when 301, 302, 303, 307, 308
            location = response['location']
            raise "Redirect loop or missing Location header" if location.nil? || location == current_uri.to_s
            current_uri = URI.parse(location)
          else
            raise "HTTP #{response.code} while downloading #{@zip_source}"
          end
        end
      end
    end

    raise "Too many redirects downloading #{@zip_source}"
  end

  # Extract the zip archive into <tmpdir>/extracted/.
  private def extract_zip(zip_path, tmpdir)
    puts "Extracting package..." unless @silent
    extracted_dir = File.join(tmpdir, 'extracted')
    FileUtils.mkdir_p(extracted_dir)

    # Prefer the 'unzip' system command; fall back to Ruby's built-in zip support via ZipFile.
    if system('which', 'unzip', out: File::NULL, err: File::NULL)
      result = system('unzip', '-q', zip_path, '-d', extracted_dir)
      raise "unzip failed (exit code #{$?.exitstatus})" unless result
    else
      # Attempt to use the 'zip' gem if available, otherwise raise a clear error.
      begin
        require 'zip'
        Zip::File.open(zip_path) do |zip|
          zip.each do |entry|
            dest = File.join(extracted_dir, entry.name)
            FileUtils.mkdir_p(File.dirname(dest))
            entry.extract(dest)
          end
        end
      rescue LoadError
        raise "Cannot extract zip: 'unzip' command not found and 'zip' gem is not installed.\n" \
              "Install unzip (e.g. brew install unzip) and try again."
      end
    end
  end

  # Walk the extracted directory and install every skill (directory containing SKILL.md).
  # Supports two zip layouts:
  #   Layout A — SKILL.md at zip root (flat): extracted/SKILL.md
  #   Layout B — skill in subdirectory:       extracted/my-skill/SKILL.md
  private def discover_and_install_skills(extracted_dir)
    # Layout A: SKILL.md directly under the extraction root.
    if File.exist?(File.join(extracted_dir, 'SKILL.md'))
      install_skill(extracted_dir, skill_name: @skill_name)
      return
    end

    # Layout B: one or more skill subdirectories each containing SKILL.md.
    skill_dirs = Dir.glob(File.join(extracted_dir, '*/SKILL.md')).map { |f| File.dirname(f) }

    if skill_dirs.empty?
      raise "No SKILL.md found in the zip archive. " \
            "Make sure the package contains a valid skill directory."
    end

    skill_dirs.each { |dir| install_skill(dir) }
  end

  # Copy a single skill directory into the target skills folder.
  # skill_name overrides the directory basename (used for Layout A flat zips).
  private def install_skill(skill_src_dir, skill_name: nil)
    name        = skill_name || File.basename(skill_src_dir)
    target_path = File.join(@target_dir, name)

    if File.exist?(target_path)
      if @skip_if_exists
        @skipped_skills << { name: name, path: target_path, reason: 'already exists' }
        return
      end
      puts "Skill '#{name}' already exists — overwriting..." unless @silent
      FileUtils.rm_rf(target_path)
    end

    FileUtils.mkdir_p(target_path)
    # Copy contents of skill_src_dir into target_path (not the dir itself).
    FileUtils.cp_r(Dir.glob("#{skill_src_dir}/*"), target_path)

    description = extract_description(File.join(target_path, 'SKILL.md'))
    @installed_skills << { name: name, path: target_path, description: description }
  rescue StandardError => e
    @errors << "Failed to install '#{name}': #{e.message}"
  end

  # Parse the description field from SKILL.md YAML frontmatter.
  private def extract_description(skill_file)
    return "No description" unless File.exist?(skill_file)

    content = File.read(skill_file)
    if content =~ /\A---\s*\n(.*?)\n---/m
      frontmatter = $1
      return $1.strip if frontmatter =~ /^description:\s*(.+)$/
    end

    "No description"
  rescue StandardError
    "No description"
  end

  # Print a human-readable summary of what was installed.
  private def report_results
    puts "\n" + "=" * 60

    if @installed_skills.empty?
      puts "No skills were installed."
      if @errors.any?
        puts "\nErrors:"
        @errors.each { |e| puts "   • #{e}" }
      end
      exit 1
    end

    puts "Installation complete!"
    puts "\nInstalled #{@installed_skills.size} skill(s):\n\n"
    @installed_skills.each do |skill|
      puts "   ✓ #{skill[:name]}"
      puts "     #{skill[:description]}"
      puts "     → #{skill[:path]}"
      puts
    end

    if @errors.any?
      puts "Warnings:"
      @errors.each { |e| puts "   • #{e}" }
      puts
    end

    puts "You can now use these skills with /skill-name"
    puts "=" * 60
  end
end

# ── Entry point ────────────────────────────────────────────────────────────────
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby install_from_zip.rb <zip_url_or_path> [skill_name]"
    puts "\nExamples:"
    puts "  ruby install_from_zip.rb https://example.com/my-skill-1.0.0.zip"
    puts "  ruby install_from_zip.rb https://example.com/my-skill-1.0.0.zip my-skill"
    puts "  ruby install_from_zip.rb /path/to/my-skill.zip"
    puts "  ruby install_from_zip.rb ~/Downloads/my-skill-1.0.0.zip my-skill"
    exit 1
  end

  ZipSkillInstaller.new(ARGV[0], skill_name: ARGV[1]).install
end
