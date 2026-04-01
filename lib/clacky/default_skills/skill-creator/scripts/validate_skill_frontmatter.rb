#!/usr/bin/env ruby
# frozen_string_literal: true

# validate_skill_frontmatter.rb
#
# Validates and auto-fixes the YAML frontmatter of a SKILL.md file.
#
# Usage:
#   ruby validate_skill_frontmatter.rb <path/to/SKILL.md>
#
# What it does:
#   1. Parses the frontmatter between --- delimiters
#   2. If YAML is invalid OR description is not a plain String:
#      - Extracts name/description via regex fallback
#      - Re-wraps description in single quotes (collapsed to one line)
#      - Rewrites the frontmatter in the file
#   3. Exits 0 on success (with or without auto-fix), 1 on unrecoverable error

require "yaml"

path = ARGV[0]

if path.nil? || path.strip.empty?
  warn "Usage: ruby validate_skill_frontmatter.rb <path/to/SKILL.md>"
  exit 1
end

unless File.exist?(path)
  warn "File not found: #{path}"
  exit 1
end

content = File.read(path)

# Extract frontmatter block
fm_match = content.match(/\A(---\n)(.*?)(\n---[ \t]*\n?)/m)
unless fm_match
  warn "ERROR: No frontmatter block found in #{path}"
  exit 1
end

prefix      = fm_match[1]          # "---\n"
yaml_raw    = fm_match[2]          # raw YAML text
suffix      = fm_match[3]          # "\n---\n"
body        = content[fm_match.end(0)..]  # rest of file after frontmatter

# Attempt normal YAML parse
parse_ok = false
data = nil
begin
  data = YAML.safe_load(yaml_raw) || {}
  parse_ok = data["description"].is_a?(String)
rescue Psych::Exception => e
  warn "YAML parse error: #{e.message}"
end

if parse_ok
  puts "OK: name=#{data['name'].inspect} description_length=#{data['description'].length}"
  exit 0
end

# --- Auto-fix ---
puts "Frontmatter invalid or description broken — attempting auto-fix..."

# Regex fallback: extract name and description lines
name_match = yaml_raw.match(/^name:\s*(.+)$/)
unless name_match
  warn "ERROR: Cannot extract 'name' field from frontmatter. Manual fix required."
  exit 1
end
name_value = name_match[1].strip.gsub(/\A['"]|['"]\z/, "")

# description may be:
#   description: some text           (unquoted)
#   description: 'some text'         (single-quoted)
#   description: "some text"         (double-quoted)
#   description: first line\n  continuation  (multi-line block scalar)
desc_match = yaml_raw.match(/^description:\s*(.+?)(?=\n[a-z]|\z)/m)
unless desc_match
  warn "ERROR: Cannot extract 'description' field from frontmatter. Manual fix required."
  exit 1
end

raw_desc = desc_match[1].strip

# Strip existing outer quotes if present (simple single-line quoted values)
if raw_desc.start_with?("'") && raw_desc.end_with?("'")
  raw_desc = raw_desc[1..-2]
elsif raw_desc.start_with?('"') && raw_desc.end_with?('"')
  raw_desc = raw_desc[1..-2]
end

# Collapse multi-line: strip leading whitespace from continuation lines
description_value = raw_desc.gsub(/\n\s+/, " ").strip

# Escape any single quotes inside the description value
description_value_escaped = description_value.gsub("'", "''")

# Extract all other frontmatter lines (everything except name: and description:)
other_lines = yaml_raw.each_line.reject do |line|
  line.match?(/^(name|description):/) || line.match?(/^\s+\S/) && yaml_raw.match?(/^description:.*\n(\s+.+\n)*/m)
end

# More precise: collect lines that are not part of the name/description block
remaining = []
skip_continuation = false
yaml_raw.each_line do |line|
  if line.match?(/^(name|description):/)
    skip_continuation = true
    next
  end
  if skip_continuation && line.match?(/^\s+\S/)
    next  # continuation of a multi-line block value
  end
  skip_continuation = false
  remaining << line unless line.strip.empty? && remaining.empty?
end

# Rebuild frontmatter
fixed_fm_lines = []
fixed_fm_lines << "name: #{name_value}"
fixed_fm_lines << "description: '#{description_value_escaped}'"
remaining.each { |l| fixed_fm_lines << l.chomp }

# Remove trailing blank lines from remaining
fixed_fm = fixed_fm_lines.join("\n").strip

new_content = "#{prefix}#{fixed_fm}#{suffix}#{body}"

File.write(path, new_content)
puts "Auto-fixed and saved: #{path}"

# Final verification
begin
  verify_content = File.read(path)
  verify_match = verify_content.match(/\A---\n(.*?)\n---/m)
  verify_data = YAML.safe_load(verify_match[1])
  raise "description not a String" unless verify_data["description"].is_a?(String)
  puts "OK: name=#{verify_data['name'].inspect} description_length=#{verify_data['description'].length}"
rescue => e
  warn "ERROR: Auto-fix failed, manual intervention required: #{e.message}"
  exit 1
end
