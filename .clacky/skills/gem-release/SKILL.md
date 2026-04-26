---
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

This skill automates the complete process of releasing a new version of the openclacky Ruby gem.

## Overview

This skill handles the entire gem release workflow from version bumping to publishing on RubyGems and creating GitHub releases.

## Usage

To use this skill, simply say:
- "Release a new version"
- "Publish a new gem version"
- "Release version 1.0.0.beta.1" (pre-release with explicit version)
- Use the command: `/gem-release`

## Process Steps

### 1. Pre-Release Checks
- Check for uncommitted changes in the working directory
- Verify all tests pass before proceeding
- Ensure the repository is in a clean state

### 2. Version Management

**Stable releases (default):**
- Read current version from `lib/clacky/version.rb`
- Increment version number (typically patch version: x.y.z → x.y.z+1)
- Update the VERSION constant in the version file

**Pre-release versions (when user specifies a version like `1.0.0.beta.1`):**
- Accept the user-provided version string directly — do NOT auto-increment
- The version must follow semver pre-release format: `X.Y.Z-<identifier>` or `X.Y.Z.<identifier>` (e.g., `1.0.0.beta.1`, `2.0.0-alpha`, `1.5.0-rc1`)
- Before proceeding, warn the user about pre-release caveats (see Pre-Release Caveats below)

### 2a. Pre-Release Caveats

When releasing a pre-release version, inform the user of these known behaviors in the Clacky ecosystem:

| Concern | Behavior | Impact |
|---------|----------|--------|
| **Version check notification** | RubyGems API returns the highest version number, including prereleases. `Gem::Version("0.9.38") < Gem::Version("1.0.0.beta.1")` → `true`. | ✅ The upgrade dot WILL appear in the Web UI for most users. |
| **`gem update` (official source)** | `gem update openclacky --no-document` does NOT install prereleases without `--pre`. | ❌ Users on official RubyGems source who click "Upgrade" will see the notification but the upgrade will silently do nothing. |
| **OSS CDN upgrade (mirror users)** | `upgrade_via_oss_cdn` downloads the exact `.gem` from `latest.txt` on OSS. | ⚠️ If you update `latest.txt` to point to the prerelease, mirror users WILL get the beta. |
| **OSS `latest.txt`** | Stable users fetching `latest.txt` for fresh installs would get the beta. | ⚠️ By default, do NOT update `latest.txt` for pre-releases. Only update if this is intentional (e.g., a release candidate for broad testing). |

**Action**: Ask the user whether to update `latest.txt` on OSS before proceeding. For internal testing, the answer is usually "no".

### 3. Quality Assurance
- Run the full test suite with `bundle exec rspec`
- Ensure all 167+ tests pass
- Verify no regressions introduced

### 4. Build Process
- Build the gem using `gem build openclacky.gemspec`
- Generate the `.gem` file for distribution
- Handle any build warnings appropriately

### 5. Update Gemfile.lock and Verify CI

1. **Update Gemfile.lock**
   ```bash
   bundle install
   ```
   This ensures Gemfile.lock reflects the new version.

2. **Commit Gemfile.lock Changes**
   ```bash
   git add Gemfile.lock
   git commit -m "chore: update Gemfile.lock to v{version}"
   ```

3. **Push and Verify CI**
   ```bash
   git push origin main
   ```
   - Wait for CI pipeline to complete successfully
   - Verify all tests pass
   - If CI fails, fix issues before proceeding

4. **Proceed Only After CI Success**
   - If CI fails: stop, fix issues, and restart the release process
   - If CI passes: continue to build and publish

### 6. Build and Publish Gem

1. **Build the Gem**
   ```bash
   gem build openclacky.gemspec
   ```
   Generates `openclacky-{version}.gem` file.

2. **Publish to RubyGems.org**
   ```bash
   gem push openclacky-{version}.gem
   ```
   Verify successful publication.

3. **Create Git Tag and Push**
   ```bash
   git tag v{version}
   git push origin main --tags
   ```

4. **Create GitHub Release and Upload gem**

   Extract the release notes for this version from CHANGELOG.md, then create a GitHub Release with the .gem file attached.

   **For stable releases:**
   ```bash
   gh release create v{version} \
     --title "v{version}" \
     --notes-file /tmp/release_notes_{version}.md \
     --latest \
     openclacky-{version}.gem
   ```

   **For pre-release versions (e.g., `1.0.0.beta.1`):** use `--prerelease` instead of `--latest`:
   ```bash
   gh release create v{version} \
     --title "v{version}" \
     --notes-file /tmp/release_notes_{version}.md \
     --prerelease \
     openclacky-{version}.gem
   ```

   Steps:
   - Parse the CHANGELOG.md section for `[{version}]`
   - Write it to a temp file (e.g., `/tmp/release_notes_{version}.md`) to avoid shell escaping issues
   - Run `gh release create` with `--notes-file` **and the .gem file as an asset**
   - Verify the release appears at: `https://github.com/clacky-ai/openclacky/releases`

   > **Prerequisite**: `gh` CLI must be installed (`brew install gh`) and authenticated (`gh auth login`)

5. **Sync to Tencent Cloud OSS (CN mirror)**

   After GitHub Release is created, upload the .gem file to OSS so Chinese users can install without hitting GitHub directly.

   ```bash
   # Upload .gem file (always do this for any release)
   coscli cp openclacky-{version}.gem cos://clackyai-1258723534/openclacky/openclacky-{version}.gem
   ```

   **For stable releases only** — update `latest.txt` so fresh installs and mirror users pick up the new version:
   ```bash
   echo "{version}" > /tmp/latest.txt
   coscli cp /tmp/latest.txt cos://clackyai-1258723534/openclacky/latest.txt

   # Verify
   curl -fsSL https://oss.1024code.com/openclacky/latest.txt
   ```
   Expected output of verify: `{version}`

   **For pre-release versions** — do NOT update `latest.txt` unless the user explicitly requested it. Updating `latest.txt` to a prerelease would cause:
   - Mirror users clicking "Upgrade" to get the beta via `upgrade_via_oss_cdn`
   - Fresh installs via the install script to get the beta
   - Only skip this if the user explicitly wants broad beta distribution

   > **Prerequisite**: `coscli` installed at `/usr/local/bin/coscli` and configured at `~/.cos.yaml`

6. **Sync scripts/ to OSS**

   After updating latest.txt, first rebuild all shell scripts from templates, then sync to OSS:

   ```bash
   # Step 1: Rebuild .sh files from .sh.cc templates
   bash scripts/build/build.sh

   # Step 2: Upload each script file to OSS
   for script in scripts/*; do
     coscli cp "$script" cos://clackyai-1258723534/clacky-ai/openclacky/main/scripts/$(basename "$script")
   done

   # Verify one of the key scripts
   curl -fsSL https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.sh | head -5
   ```

   This ensures `scripts/install.sh`, `scripts/install_simple.sh`, `scripts/install.ps1`, `scripts/uninstall.sh` and any future scripts are compiled from latest templates and mirrored on OSS.

   > **Prerequisite**: Same `coscli` setup as above

5. **Verify Publication**
   - Check gem appears on RubyGems.org
   - Verify version information is correct
   - Confirm GitHub Release is visible at the releases page

### 6. Documentation - CHANGELOG Writing Process

**Critical Step: Review Commits Before Writing CHANGELOG**

1. **Find Previous Version Tag**
   - Get the latest version tag (e.g., v0.6.3)
   - Use `git describe --tags --abbrev=0` or manually identify

2. **Gather All Commits Since Last Release**
   ```bash
   git log {previous_tag}..HEAD --oneline
   git diff {previous_tag}..HEAD --stat
   ```

3. **Analyze and Categorize Commits**
   - Review each commit message AND its diff (`git show <hash> --stat`) to understand the actual change
   - Categorize into:
     - **Major Features**: User-visible functionality additions
     - **Improvements**: Performance, UX, architecture enhancements
     - **Bug Fixes**: Error corrections and issue resolutions
     - **Changes**: Breaking changes or significant refactoring
     - **Minor Details**: Small fixes, style changes, trivial updates

   **⚠️ Critical: Do NOT over-merge commits on the same topic**

   It is tempting to group multiple commits under one bullet because they share a theme (e.g., "all about memory"). Resist this — each commit with **independent user-facing value** deserves its own bullet.

   Ask for every commit: *"Does this enable something the user couldn't do before, separate from other commits on this topic?"*
   - YES → write a separate CHANGELOG bullet
   - NO (pure refactor, stability fix, threshold tweak) → merge into a related bullet or put in "More"

   **Example of the mistake to avoid:**
   - `feat: add long-term memory update system` and `feat: skill template context and recall-memory meta injection` are both "about memory", but they describe distinct capabilities:
     - First: agent writes memories after sessions
     - Second: skills receive a pre-built index so agent can selectively load only relevant memories
   - These must be two separate bullets, not one.

   **Sanity check after writing:** Count your `### Added` bullets vs the number of `feat:` commits. If `feat` commits > bullets, you likely merged too aggressively — revisit.

4. **Write CHANGELOG Entries**

   **Format for Significant Items:**
   ```
   ## [Version] - Date

   ### Added
   - Feature description (link to related commits)

   ### Improved
   - Enhancement description

   ### Fixed
   - Bug fix description

   ### Changed
   - Breaking change description
   ```

   **Format for Minor Items (group under "More"):**
   ```
   ### More
   - Minor fix 1
   - Minor fix 2
   ```

5. **Prioritization Rules**:
   - Place user-facing value at the top
   - Group related commits together
   - Skip very trivial commits (typos, minor formatting)
   - Use imperative mood ("Add" not "Added")

6. **Example CHANGELOG Section**:
   ```markdown
   ## [0.6.4] - 2026-02-03

   ### Added
   - Anthropic API support with full Claude model integration
   - ClaudeCode environment compatibility (ANTHROPIC_API_KEY support)

   ### Improved
   - API client architecture for multi-provider support
   - Config loading with source tracking

   ### Fixed
   - Handle absolute paths correctly in glob tool

   ### More
   - Update dependencies
   - Minor style adjustments
   ```

7. **Commit and Push Documentation Updates**
   - Commit CHANGELOG.md changes
   - Push to remote repository

### 7. Final Summary

Present a clear, user-facing release summary after all steps complete:

**Format:**
```
🎉 v{version} released successfully!

✨ Highlight: [One sentence summarizing the biggest user-visible change in this release — use "verb + value" phrasing]

📦 What's new for users:

**New Features**
- [translate each "Added" item into plain user-facing language]

**Improvements**
- [translate each "Improved" item into plain user-facing language]

**Bug Fixes**
- [translate each "Fixed" item into plain user-facing language]

🧪 Testing suggestions:
| Feature | How to verify |
|---------|--------------|
| [key new feature] | [concrete steps to test] |
...

🔗 Links:
- RubyGems: https://rubygems.org/gems/openclacky/versions/{version}
- GitHub Release: https://github.com/clacky-ai/openclacky/releases/tag/v{version}

⬆️ Upgrade:
- In the Clacky UI, click "Upgrade" in the bottom-left → detect new version → click upgrade → done
- Manual upgrade (CLI): `gem update openclacky`

🆕 Fresh install:
/bin/bash -c "$(curl -sSL https://raw.githubusercontent.com/clacky-ai/openclacky/main/scripts/install.sh)"
```

**Rules for writing the summary:**
- Highlight: pick the single most impactful user-visible change, use "verb + value" phrasing, e.g. "Real browser control + WeChat channel support — agents can now navigate pages and chat via WeChat"
- Write from the user's perspective — what can they now do, or what problem is now fixed
- Avoid technical jargon (no "cursor-paginated", "frontmatter", "REST API" — explain what it means instead)
- Skip "More" / chore items unless they directly affect users
- Keep each bullet to one sentence, action-oriented
- Example translation: `fix: expand ~ in file system tools path arguments` → "File paths starting with `~` (home directory) now work correctly in all file tools"
- Testing suggestions: list only significant new features (3–8 items), each with concrete, actionable verification steps

## Commands Used

```bash
# Pre-release checks
git status --porcelain

# Run tests
bundle exec rspec

# Update Gemfile.lock
bundle install
git add Gemfile.lock
git commit -m "chore: update Gemfile.lock to vX.Y.Z"
git push origin main

# Build and publish gem
gem build openclacky.gemspec
gem push openclacky-X.Y.Z.gem

# Git operations
git add lib/clacky/version.rb
git commit -m "chore: bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin --tags

# ── GitHub Release ──────────────────────────────────────────────────────

# Stable release:
gh release create vX.Y.Z \
  --title "vX.Y.Z" \
  --notes-file /tmp/release_notes_X.Y.Z.md \
  --latest \
  openclacky-X.Y.Z.gem

# Pre-release (use --prerelease instead of --latest):
gh release create vX.Y.Z-beta.1 \
  --title "vX.Y.Z-beta.1" \
  --notes-file /tmp/release_notes_X.Y.Z-beta.1.md \
  --prerelease \
  openclacky-X.Y.Z.beta.1.gem

# ── OSS CDN (CN mirror) ─────────────────────────────────────────────────

# Always upload the .gem file:
coscli cp openclacky-X.Y.Z.gem cos://clackyai-1258723534/openclacky/openclacky-X.Y.Z.gem

# Stable releases ONLY — update latest.txt:
echo "X.Y.Z" > /tmp/latest.txt
coscli cp /tmp/latest.txt cos://clackyai-1258723534/openclacky/latest.txt
curl -fsSL https://oss.1024code.com/openclacky/latest.txt  # verify

# Pre-releases — skip latest.txt update unless user explicitly requests it

# Sync scripts/ to OSS (build from templates first)
bash scripts/build/build.sh
for script in scripts/*; do
  coscli cp "$script" cos://clackyai-1258723534/clacky-ai/openclacky/main/scripts/$(basename "$script")
done
curl -fsSL https://oss.1024code.com/clacky-ai/openclacky/main/scripts/install.sh | head -5  # verify
```

## File Locations

- Version file: `lib/clacky/version.rb`
- Gem specification: `openclacky.gemspec`
- Changelog: `CHANGELOG.md`
- Built gem: `openclacky-{version}.gem`

## Success Criteria

- All tests pass
- CI pipeline completes successfully
- Gemfile.lock updated and committed
- New version successfully published to RubyGems
- Git repository updated with version tag
- CHANGELOG.md updated with release notes
- GitHub Release created with .gem file attached at https://github.com/clacky-ai/openclacky/releases
  - Use `--latest` for stable releases, `--prerelease` for pre-releases
- .gem file uploaded to OSS: https://oss.1024code.com/openclacky/openclacky-{version}.gem
- For stable releases: `latest.txt` updated on OSS: https://oss.1024code.com/openclacky/latest.txt returns the new version
- For pre-releases: `latest.txt` NOT updated (unless user explicitly opts in)
- No build or deployment errors
- User-facing release summary presented at the end

## Error Handling

- If tests fail, stop the process and report issues
- If CI fails after Gemfile.lock update, fix issues before proceeding
- If gem build fails, check gemspec configuration
- If git push fails, verify repository permissions
- If gem push fails, check RubyGems credentials
- If `gh release create` fails, ensure `gh` CLI is installed (`brew install gh`) and authenticated (`gh auth login`)
- If GitHub Release notes look wrong, check CHANGELOG.md formatting for the version section

## Notes

- This skill follows semantic versioning
- Always update CHANGELOG.md as part of the release
- Verify RubyGems.org shows the new version after publication
- The search index on RubyGems may take a few minutes to update

## Dependencies

- Ruby development environment
- Git repository access
- RubyGems account with push permissions
- Bundle and RSpec for testing
- `gh` CLI installed and authenticated (`brew install gh && gh auth login`)

## Version History

- Created: 2026-01-18
- Used for: openclacky gem releases
- Compatible with: Ruby gems following standard conventions

## User Experience Summary

This skill takes the complexity out of gem releases. Instead of remembering 8+ different commands and worrying about the correct order, you just say "release a new version" and the AI handles everything - from running tests to publishing on RubyGems. It's like having an experienced release engineer on your team who never forgets a step, always runs the tests first, and makes sure your changelog is updated. The whole process that used to take 15-20 minutes and multiple terminal windows now happens smoothly in one conversation, with clear feedback at each step so you know exactly what's happening.