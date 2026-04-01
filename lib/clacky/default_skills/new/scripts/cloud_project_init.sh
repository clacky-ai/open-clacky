#!/bin/bash
# Cloud Project Init Script
# Connects the local Rails project to the Clacky cloud platform.
#
# Usage: cloud_project_init.sh [project_name] [workspace_key] [base_url]
#   - project_name:  defaults to current directory name
#   - workspace_key: defaults to value in ~/.clacky/platform.yml
#   - base_url:      defaults to https://api.clacky.ai
#
# Outputs a JSON result on stdout:
#   { "success": true,  "project_id": "...", "project_name": "..." }
#   { "success": false, "error": "..." }

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GEM_LIB_DIR="$( cd "$SCRIPT_DIR/../../../.." && pwd )"

PROJECT_NAME="${1:-$(basename "$PWD")}"
WORKSPACE_KEY="${2:-}"
BASE_URL="${3:-}"

# --- Load workspace_key from platform.yml if not provided ---
if [ -z "$WORKSPACE_KEY" ]; then
  PLATFORM_YML="$HOME/.clacky/platform.yml"
  if [ -f "$PLATFORM_YML" ]; then
    WORKSPACE_KEY=$(ruby -e "require 'yaml'; y = YAML.safe_load(File.read('$PLATFORM_YML')); print y['workspace_key'].to_s.strip" 2>/dev/null || true)
  fi
fi

if [ -z "$BASE_URL" ]; then
  PLATFORM_YML="$HOME/.clacky/platform.yml"
  if [ -f "$PLATFORM_YML" ]; then
    BASE_URL=$(ruby -e "require 'yaml'; y = YAML.safe_load(File.read('$PLATFORM_YML')); print y['base_url'].to_s.strip" 2>/dev/null || true)
  fi
  BASE_URL="${BASE_URL:-https://api.clacky.ai}"
fi

if [ -z "$WORKSPACE_KEY" ]; then
  echo '{"success":false,"error":"No workspace_key found. Please set it in ~/.clacky/platform.yml or pass as argument."}'
  exit 0
fi

# --- Call the API via Ruby one-liner using the gem's CloudProjectClient ---
RUBY_SCRIPT=$(cat <<'RUBY'
require_relative ENV['GEM_LIB_DIR'] + '/clacky/cloud_project_client'
require 'json'

workspace_key = ENV['WORKSPACE_KEY']
base_url      = ENV['BASE_URL']
project_name  = ENV['PROJECT_NAME']

client = Clacky::CloudProjectClient.new(workspace_key, base_url: base_url)
result = client.create_project(name: project_name)

if result[:success]
  project = result[:project]
  puts JSON.generate({
    success: true,
    project_id:   project['id'],
    project_name: project['name'],
    categorized_config: project['categorized_config'] || {}
  })
else
  puts JSON.generate({ success: false, error: result[:error] })
end
RUBY
)

GEM_LIB_DIR="$GEM_LIB_DIR" \
WORKSPACE_KEY="$WORKSPACE_KEY" \
BASE_URL="$BASE_URL" \
PROJECT_NAME="$PROJECT_NAME" \
ruby -e "$RUBY_SCRIPT"
