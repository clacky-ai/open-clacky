---
name: gem-release
description: >-
  Automates the complete process of releasing a new version of the openclacky Ruby
  gem. Supports both stable releases (auto-increment) and pre-release versions
  (user-specified, e.g., 1.0.0.beta.1). Handles version bumping, testing, building,
  RubyGems publishing, GitHub Releases, and OSS CDN mirroring.
disable-model-invocation: false
user-invocable: true
---

# Gem Release Skill

Automates the complete openclacky gem release workflow via `SKILL_DIR/scripts/release.sh`.

## Usage

- "Release a new version"
- "Publish a new gem version"
- "Release version 1.0.0.beta.1" (pre-release with explicit version)
- `/gem-release`

## Workflow

The release script (`SKILL_DIR/scripts/release.sh`) handles everything end-to-end:

1. Pre-release checks (clean working directory, required tools)
2. Run test suite (`bundle exec rspec`)
3. Bump version in `lib/clacky/version.rb`
4. Update `Gemfile.lock` via `bundle install`
5. Commit and push to origin, wait for CI
6. Build gem (`gem build openclacky.gemspec`)
7. Publish to RubyGems (`gem push`)
8. Create git tag and push
9. Create GitHub Release with .gem asset (uses CHANGELOG.md for notes)
10. Upload .gem to Tencent Cloud OSS CDN
11. Update `latest.txt` on OSS (stable only, unless `--update-latest`)
12. Rebuild and sync `scripts/` to OSS
13. Cleanup build artifacts

## Agent Instructions

### 1. Determine version and release type

Read current version:
```bash
grep 'VERSION =' lib/clacky/version.rb
```

**Stable release (default):** Increment patch version (e.g., `1.0.5` → `1.0.6`). Confirm with user if unsure which part to bump (major/minor/patch).

**Pre-release:** Use the exact version the user specified (e.g., `2.0.0.beta.1`). Before proceeding, warn about pre-release caveats (see section below).

### 2. Write CHANGELOG

This is the one step the agent handles manually — the script does not write changelog entries because it requires reviewing git history and exercising judgment.

1. Find the previous version tag:
   ```bash
   git describe --tags --abbrev=0
   ```

2. Gather commits since last release:
   ```bash
   git log <previous_tag>..HEAD --oneline
   ```

3. Write a new section in `CHANGELOG.md` following this format:
   ```markdown
   ## [X.Y.Z] - YYYY-MM-DD

   ### Added
   - Feature description

   ### Improved
   - Enhancement description

   ### Fixed
   - Bug fix description

   ### More
   - Minor items
   ```

4. Categorization rules:
   - Each commit with **independent user-facing value** gets its own bullet — don't over-merge commits sharing a theme
   - Use imperative mood ("Add" not "Added")
   - Place user-facing value at the top
   - Skip trivial commits (typos, minor formatting)
   - Sanity check: count `### Added` bullets vs `feat:` commits — if commits > bullets, you likely merged too aggressively

5. Commit the changelog:
   ```bash
   git add CHANGELOG.md
   git commit -m "docs: update CHANGELOG for v<version>"
   ```

### 3. Run the release script

**Stable release:**
```bash
bash "SKILL_DIR/scripts/release.sh" <version>
```

**Pre-release (skip latest.txt):**
```bash
bash "SKILL_DIR/scripts/release.sh" <version> --prerelease
```

**Pre-release (update latest.txt — only if user explicitly requested):**
```bash
bash "SKILL_DIR/scripts/release.sh" <version> --prerelease --update-latest
```

**Dry run (preview only):**
```bash
bash "SKILL_DIR/scripts/release.sh" <version> --dry-run
```

The script runs all steps sequentially and stops on any failure. Monitor the output — if a step fails, diagnose and fix before retrying.

### 4. Present release summary

After the script completes successfully, present a concise summary. The output will often be read in WeChat, so keep it compact and avoid template-like formatting that triggers message folding.

Rules:
- No emojis
- No tables (use a compact list if you need to list items)
- No multi-line code blocks
- Write as a natural, flowing message — not a structured report
- Skip "More" / chore items unless they directly affect users
- Write from the user's perspective — what they can now do, or what problem is fixed
- Translate technical terms into plain language
- Keep each item one sentence, action-oriented

Format (flexible — adapt as needed, but roughly):

```
v{version} released.

[One sentence highlight — the biggest user-visible change.]

Added:
- [translate each "Added" item]
- ...

Improved:
- [translate each "Improved" item]
- ...

Fixed:
- [translate each "Fixed" item]
- ...

Upgrade: click "Upgrade" in Web UI bottom-left, or `gem update openclacky`
Fresh install: curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.sh | bash

RubyGems: https://rubygems.org/gems/openclacky/versions/{version}
GitHub: https://github.com/clacky-ai/openclacky/releases/tag/v{version}
```

## Pre-Release Caveats

When releasing a pre-release version, inform the user of these behaviors:

| Concern | Behavior | Impact |
|---------|----------|--------|
| **Version check notification** | `Gem::Version("0.9.38") < Gem::Version("1.0.0.beta.1")` is true | The upgrade dot WILL appear in the Web UI for most users |
| **`gem update` (official source)** | Does NOT install prereleases without `--pre` | Users who click "Upgrade" will see notification but upgrade silently does nothing |
| **OSS CDN upgrade (mirror users)** | Downloads exact `.gem` from `latest.txt` | If latest.txt points to prerelease, mirror users WILL get the beta |
| **OSS `latest.txt`** | Fresh installs fetch latest.txt | By default, do NOT update latest.txt for pre-releases |

Ask the user whether to use `--update-latest` before running the script.

## Error Handling

The script uses `set -euo pipefail` and stops on any failure. Common issues:

- **Tests fail** → fix tests before re-running
- **CI fails** → script pushes then watches CI; fix and re-push if needed
- **gem push fails** → check RubyGems credentials (`gem signin`)
- **gh release fails** → check `gh auth status`
- **coscli fails** → check `~/.cos.yaml` config

After fixing an issue, you can re-run the script — it's safe to retry. If a partial release happened (e.g., gem pushed but tag not created), handle remaining steps manually.

## File Locations

- Release script: `SKILL_DIR/scripts/release.sh`
- Version file: `lib/clacky/version.rb`
- Gem specification: `openclacky.gemspec`
- Changelog: `CHANGELOG.md`

## Dependencies

- Ruby >= 3.1.0, Bundler, RSpec
- `gh` CLI installed and authenticated
- `coscli` installed at `/usr/local/bin/coscli` with `~/.cos.yaml`
- RubyGems push credentials
