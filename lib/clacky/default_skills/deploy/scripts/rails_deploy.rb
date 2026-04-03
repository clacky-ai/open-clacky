# frozen_string_literal: true

# Ensure all output is flushed immediately so users see live progress
# even when the script is run inside a subprocess (safe_shell / Open3).
$stdout.sync = true
$stderr.sync = true

require "yaml"
require "json"
require "fileutils"
require "open3"

# Load gem libs — resolve path relative to this script's location
DEPLOY_SCRIPT_DIR = File.expand_path("..", __FILE__)
GEM_LIB_DIR       = File.expand_path("../../../../..", DEPLOY_SCRIPT_DIR)

$LOAD_PATH.unshift(GEM_LIB_DIR) unless $LOAD_PATH.include?(GEM_LIB_DIR)

require "clacky/platform_config"
require "clacky/cloud_project_client"
require "clacky/deploy_api_client"

require_relative "../tools/execute_deployment"
require_relative "../tools/set_deploy_variables"
require_relative "../tools/list_services"
require_relative "../tools/fetch_runtime_logs"
require_relative "../tools/check_health"

module Clacky
  module DeployTemplates
    # RailsDeploy — three-phase automated deployment to Railway via Clacky platform.
    #
    # Phase 0: Cloud project binding check (openclacky.yml + workspace_key + API)
    # Phase 1: Subscription / payment check
    # Phase 2: 8-step Railway deployment
    class RailsDeploy

      PAYMENT_POLL_INTERVAL = 10   # seconds between payment status checks
      PAYMENT_POLL_MAX      = 18   # max attempts (180 seconds / 3 minutes total)
      DB_POLL_INTERVAL      = 2    # seconds between service readiness checks
      DB_POLL_MAX           = 60   # max attempts (120 seconds total)
      DEPLOY_POLL_INTERVAL  = 5    # seconds between deploy status checks
      DEPLOY_POLL_MAX       = 60   # max attempts (300 seconds total)

      # DASHBOARD_BASE_URL is resolved dynamically from PlatformConfig#dashboard_url
      # so it automatically tracks the environment (prod / staging / local).
      DASHBOARD_PATH = "/dashboard/openclacky-project"

      def self.execute
        new.run
      end

      # -----------------------------------------------------------------------
      # Top-level orchestration
      # -----------------------------------------------------------------------

      def run
        print_banner

        # Phase 0: binding + workspace key + project details
        phase0 = run_phase0
        return phase0 unless phase0[:success]

        # @dashboard_base_url is set by load_platform_config during Phase 0
        project       = phase0[:project]
        project_id    = phase0[:project_id]
        api_client    = phase0[:api_client]

        # Phase 1: subscription / payment
        phase1 = run_phase1(project, project_id, api_client)
        return phase1 unless phase1[:success]

        # Phase 2: deploy
        run_phase2(project, project_id, api_client)
      end

      # -----------------------------------------------------------------------
      # Phase 0 — Cloud project binding check
      # -----------------------------------------------------------------------

      def run_phase0
        puts "\n[Phase 0] Verifying cloud project binding...\n"

        # 0.1 Read .clacky/openclacky.yml
        print "  📄 Reading project binding file..."
        binding_result = load_binding_file
        return binding_result unless binding_result[:success]
        project_id = binding_result[:project_id]
        puts " ✅ (#{project_id})"

        # 0.2 Load platform config (workspace_key)
        print "  🔑 Loading platform config..."
        cfg_result = load_platform_config
        return cfg_result unless cfg_result[:success]
        workspace_key = cfg_result[:workspace_key]
        base_url      = cfg_result[:base_url]
        puts " ✅"

        # 0.3 Fetch project details from API
        print "  🌐 Verifying project with Clacky API..."
        api_client    = DeployApiClient.new(workspace_key, base_url: base_url)
        cloud_client  = CloudProjectClient.new(workspace_key, base_url: base_url)

        project_result = fetch_project(cloud_client, api_client, project_id, workspace_key, base_url)
        return project_result unless project_result[:success]

        puts " ✅"
        puts "✅ Cloud project verified: #{project_result[:project]["name"]} (#{project_id})"

        {
          success:      true,
          project:      project_result[:project],
          project_id:   project_id,
          api_client:   api_client,
          cloud_client: cloud_client
        }
      end

      # -----------------------------------------------------------------------
      # Phase 1 — Subscription check
      # -----------------------------------------------------------------------

      def run_phase1(project, project_id, api_client)
        puts "\n[Phase 1] Checking subscription status...\n"

        subscription = project["subscription"]
        status       = subscription&.dig("status").to_s.upcase

        case status
        when "PAID"
          puts "✅ Subscription active (PAID)"
          { success: true }
        when "FREEZE"
          puts "⚠️  Subscription expiring soon (FREEZE). Continuing deployment..."
          { success: true }
        when "SUSPENDED"
          hard_fail("Subscription is SUSPENDED. Please contact support.")
        else
          # nil / "OFF" / "CANCELLED" → payment required
          run_payment_flow(project, project_id, api_client)
        end
      end

      # -----------------------------------------------------------------------
      # Phase 2 — Railway deployment (8 steps)
      # -----------------------------------------------------------------------

      def run_phase2(project, project_id, api_client)
        puts "\n[Phase 2] Starting Railway deployment...\n"

        # Pre-check: railway CLI installed?
        unless railway_cli_available?
          return hard_fail(
            "Railway CLI not found.\n" \
            "  Install: npm install -g @railway/cli\n" \
            "  Then retry deployment."
          )
        end

        # Step 0: ensure Gemfile.lock includes x86_64-linux platform
        step0 = step0_prepare_linux_platform
        return step0 unless step0[:success]

        # Step 0b: let user choose a deployment region
        region_step = step0b_select_region(api_client)
        return region_step unless region_step[:success]
        selected_region = region_step[:region]

        # Step 1: create deploy task (pass selected region if any)
        task = step1_create_task(project_id, api_client, region: selected_region)
        return task unless task[:success]

        platform_token         = task[:platform_token]
        # platform_token is used for all Railway CLI commands (link, variables, up, run, etc.)
        # as well as Clacky internal API calls.
        railway_token          = platform_token
        platform_project_id    = task[:platform_project_id]
        deploy_task_id         = task[:deploy_task_id]
        deploy_service_id      = task[:deploy_service_id]

        # Step 2: railway link
        link = step2_railway_link(railway_token, platform_project_id)
        return link unless link[:success]
        main_service_name = link[:service_name]

        # Step 3: inject env vars
        env_result = step3_inject_env_vars(main_service_name, project, railway_token)
        return env_result unless env_result[:success]

        # Step 4: wait for DB + inject DATABASE_URL + bind domain
        # Also returns bucket_credentials from the Clacky services API
        step4 = step4_wait_db_and_bind(deploy_task_id, main_service_name, api_client, railway_token)
        return step4 unless step4[:success]
        domain_name        = step4[:domain_name]
        bucket_credentials = step4[:bucket_credentials]
        bucket_name        = step4[:bucket_name]

        # Inject storage bucket credentials if available (separate from main env vars
        # because we need to call services API first to get them)
        if bucket_credentials
          step3b_inject_bucket_vars(main_service_name, bucket_credentials, bucket_name, railway_token)
        end

        # Step 5: trigger build
        build = step5_trigger_build(main_service_name, project_id, deploy_task_id, api_client, railway_token)
        return build unless build[:success]

        # Step 6: monitor deploy status
        monitor = step6_monitor_status(deploy_task_id, project_id, deploy_service_id, api_client,
                                       main_service_name, railway_token)
        return monitor unless monitor[:success]

        # Step 7: database migrations
        step7_run_migrations(main_service_name, railway_token)

        # Step 8: health check + notify success
        step8_finish(domain_name, project_id, deploy_task_id, deploy_service_id, api_client)
      end

      # -----------------------------------------------------------------------
      # Phase 0 helpers
      # -----------------------------------------------------------------------

      def load_binding_file
        binding_file = ".clacky/openclacky.yml"

        unless File.exist?(binding_file)
          return run_create_cloud_project
        end

        data       = YAML.safe_load(File.read(binding_file)) || {}
        project_id = data["project_id"].to_s.strip

        if project_id.empty?
          return hard_fail(
            ".clacky/openclacky.yml exists but project_id is missing.\n" \
            "  The file may be corrupted. Delete it and run /new to reinitialize."
          )
        end

        { success: true, project_id: project_id }
      rescue => e
        hard_fail("Failed to read .clacky/openclacky.yml: #{e.message}")
      end

      def load_platform_config
        cfg = PlatformConfig.load

        if cfg.workspace_key.nil? || cfg.workspace_key.empty?
          return hard_fail(
            "No Clacky workspace key configured (~/.clacky/platform.yml).\n" \
            "  Obtain a workspace key offline, then run:\n" \
            "    clacky config set workspace_key <clacky_ak_xxx>"
          )
        end

        # Store dashboard base so payment_flow and step8 use the right environment URL
        @dashboard_base_url = "#{cfg.dashboard_url}#{DASHBOARD_PATH}"

        { success: true, workspace_key: cfg.workspace_key, base_url: cfg.base_url }
      end

      def fetch_project(cloud_client, api_client, project_id, workspace_key, base_url)
        result = cloud_client.get_project(project_id)

        # 404 or project missing → recreate cloud project
        if !result[:success] && result[:error].to_s.include?("404")
          puts "⚠️  Cloud project not found (404). Creating a new one..."
          return run_create_cloud_project
        end

        unless result[:success]
          return hard_fail("Unable to verify project: #{result[:error]}\n" \
                           "  Check your network connection and workspace key.")
        end

        { success: true, project: result[:project] }
      end

      # Inline cloud project creation — reuses cloud_project_init.sh
      # Only creates the cloud record + writes .clacky/openclacky.yml.
      # Does NOT clone template, run bin/setup, or start a server.
      def run_create_cloud_project
        puts "\n📦 Initializing cloud project binding...\n"

        script = File.expand_path(
          "../../new/scripts/cloud_project_init.sh",
          DEPLOY_SCRIPT_DIR
        )

        unless File.exist?(script)
          return hard_fail("cloud_project_init.sh not found at: #{script}")
        end

        project_name = File.basename(Dir.pwd)
        env = {
          "GEM_LIB_DIR"  => GEM_LIB_DIR,
          "PROJECT_NAME" => project_name
        }

        output, status = Open3.capture2(env, "bash", script, project_name)

        unless status.success?
          return hard_fail("Cloud project creation failed (exit #{status.exitstatus})")
        end

        result = JSON.parse(output.strip)

        unless result["success"]
          return hard_fail("Cloud project creation failed: #{result["error"]}")
        end

        project_id   = result["project_id"]
        project_name = result["project_name"]

        # Write .clacky/openclacky.yml
        write_binding_file(project_id, project_name)

        # Write integration env vars if categorized_config present
        write_categorized_config(result["categorized_config"]) if result["categorized_config"]

        puts "✅ Cloud project created: #{project_name} (#{project_id})"
        puts "   Restarting Phase 0 with new project..."

        # Re-enter Phase 0 with new binding
        load_binding_file
      rescue JSON::ParserError => e
        hard_fail("Cloud project init returned invalid JSON: #{e.message}\n  Raw: #{output.to_s[0, 200]}")
      rescue => e
        hard_fail("Cloud project creation error: #{e.message}")
      end

      def write_binding_file(project_id, project_name)
        FileUtils.mkdir_p(".clacky")
        File.write(".clacky/openclacky.yml", <<~YAML)
          project_id: #{project_id}
          project_name: #{project_name}
        YAML
      end

      def write_categorized_config(categorized_config)
        return if categorized_config.nil? || categorized_config.empty?

        # Flatten all categories into a single env hash
        env_vars = {}
        categorized_config.each_value do |vars|
          next unless vars.is_a?(Hash)
          vars.each { |k, v| env_vars[k.to_s] = v.to_s }
        end

        return if env_vars.empty?

        # Append to .env.development.local
        env_file = ".env.development.local"
        File.open(env_file, "a") do |f|
          f.puts "\n# Clacky platform integrations (auto-generated)"
          env_vars.each { |k, v| f.puts "#{k}=#{v}" }
        end

        # Append to config/application.yml if it exists
        app_yml = "config/application.yml"
        if File.exist?(app_yml)
          File.open(app_yml, "a") do |f|
            f.puts "\n  # Clacky platform integrations (auto-generated)"
            env_vars.each { |k, v| f.puts "  #{k}: \"#{v}\"" }
          end
        end
      end

      # -----------------------------------------------------------------------
      # Phase 1 helpers
      # -----------------------------------------------------------------------

      def run_payment_flow(project, project_id, api_client)
        project_name = project["name"]

        puts "\n❌ Deployment blocked: Clacky subscription required."
        puts "   Project : #{project_name} (#{project_id})"
        puts "   Status  : #{project.dig("subscription", "status") || "none"}"
        puts "\n   Please subscribe to continue deployment."

        payment_url = "#{@dashboard_base_url}/#{project_id}"
        open_browser(payment_url)
        puts "\n🌐 Payment page opened:"
        puts "   #{payment_url}"
        puts "\n⏳ Waiting for payment confirmation (3 minutes)...\n\n"

        # Poll payment status with live countdown
        total_seconds = PAYMENT_POLL_INTERVAL * PAYMENT_POLL_MAX  # 180s

        PAYMENT_POLL_MAX.times do |i|
          # Poll first, then sleep — so we check immediately after each interval
          sleep PAYMENT_POLL_INTERVAL

          result = api_client.payment_status(project_id: project_id)

          if result[:success] && result[:is_paid]
            puts "\r   ✅ Payment confirmed!                              "
            return { success: true }
          end

          remaining = total_seconds - ((i + 1) * PAYMENT_POLL_INTERVAL)
          if remaining > 0
            print "\r   ⏳ Checking payment status... #{remaining}s remaining  "
          else
            print "\r   ⏰ Time's up.                                     "
          end
          $stdout.flush
        end

        # Timeout — exit with clear guidance, no further prompting
        puts "\n"
        hard_fail(
          "Payment not confirmed within 3 minutes.\n" \
          "  Once you've completed payment, re-run: /deploy"
        )
      end

      # -----------------------------------------------------------------------
      # Phase 2 step helpers
      # -----------------------------------------------------------------------

      # Fetch deployment regions from the API and prompt the user to pick one.
      # Falls back gracefully: if API fails or returns an empty list, asks the user
      # to input a region manually; entering nothing skips region selection entirely.
      #
      # @param api_client [DeployApiClient]
      # @return [Hash] { success: true, region: String | nil }
      def step0b_select_region(api_client)
        puts "\n[Step 0b] Selecting deployment region..."

        result = api_client.regions

        regions = if result[:success] && result[:regions].any?
                    result[:regions]
                  else
                    warn "  ⚠️  Could not fetch region list: #{result[:error]}" unless result[:success]
                    []
                  end

        if regions.empty?
          # Manual fallback
          print "  Enter a region slug (leave blank to skip): "
          input = $stdin.gets.to_s.strip
          region = input.empty? ? nil : input
          puts region ? "  ✅ Region set to: #{region}" : "  ℹ️  No region specified, using platform default"
          return { success: true, region: region }
        end

        # Display numbered list
        puts "  Available regions:"
        regions.each_with_index do |r, idx|
          label = r["label"] || r["name"] || r["id"] || r.to_s
          id    = r["id"]    || r["name"] || r.to_s
          puts "    #{idx + 1}) #{label}  [#{id}]"
        end

        # Prompt for selection
        print "  Select region (1-#{regions.size}, or press Enter to use default): "
        input = $stdin.gets.to_s.strip

        if input.empty?
          puts "  ℹ️  No region selected, using platform default"
          return { success: true, region: nil }
        end

        choice = input.to_i
        unless choice.between?(1, regions.size)
          puts "  ⚠️  Invalid selection '#{input}', using platform default"
          return { success: true, region: nil }
        end

        selected = regions[choice - 1]
        region   = selected["id"] || selected["name"] || selected.to_s
        label    = selected["label"] || selected["name"] || region
        puts "  ✅ Region selected: #{label} [#{region}]"

        { success: true, region: region }
      rescue Interrupt
        puts "\n  ℹ️  Region selection cancelled, using platform default"
        { success: true, region: nil }
      end

      def step0_prepare_linux_platform
        puts "\n[Step 0] Preparing project for Railway deployment..."

        # 0-A: Ensure Dockerfile exists with optimal layer-caching structure
        dockerfile_result = ensure_dockerfile
        return dockerfile_result unless dockerfile_result[:success]

        # 0-B: Ensure railway.toml exists with DOCKERFILE builder + preDeployCommand
        toml_result = ensure_railway_toml
        return toml_result unless toml_result[:success]

        # 0-C: Ensure Gemfile.lock includes x86_64-linux platform
        gemfile_result = ensure_linux_platform
        return gemfile_result unless gemfile_result[:success]

        # 0-D: Commit any generated/modified files so Railway picks them up
        commit_result = commit_deploy_files
        return commit_result unless commit_result[:success]

        puts "✅ Step 0 complete — project is Railway-ready"
        { success: true }
      end

      # -----------------------------------------------------------------------
      # Step 0 sub-helpers
      # -----------------------------------------------------------------------

      def ensure_dockerfile
        if File.exist?("Dockerfile")
          puts "  ✅ Dockerfile already exists"
          return { success: true }
        end

        hard_fail(
          "Dockerfile not found.\n" \
          "  A Dockerfile is required for Railway deployment.\n" \
          "  The rails-template-7x-starter includes one by default — " \
          "make sure you haven't accidentally deleted it."
        )
      end

      def ensure_railway_toml
        toml_path = "railway.toml"

        if File.exist?(toml_path)
          puts "  ✅ railway.toml already exists"
          return { success: true }
        end

        hard_fail(
          "railway.toml not found.\n" \
          "  A railway.toml is required for Railway deployment.\n" \
          "  The rails-template-7x-starter includes one by default — " \
          "make sure you haven't accidentally deleted it."
        )
      end

      def ensure_linux_platform
        # Check 1: Gemfile.lock must exist
        unless File.exist?("Gemfile.lock")
          return hard_fail(
            "Gemfile.lock not found.\n" \
            "  Run `bundle install` first to generate it."
          )
        end

        # Check 2: x86_64-linux must already be present
        lock_content = File.read("Gemfile.lock")
        if platform_already_present?(lock_content, "x86_64-linux")
          puts "  ✅ x86_64-linux platform already present in Gemfile.lock"
          return { success: true }
        end

        hard_fail(
          "x86_64-linux platform is missing from Gemfile.lock.\n" \
          "  Run: bundle lock --add-platform x86_64-linux\n" \
          "  Then commit the updated Gemfile.lock and retry."
        )
      end

      def commit_deploy_files
        # Collect files that are git-tracked and have uncommitted changes
        files_to_commit = %w[Dockerfile railway.toml Gemfile.lock].select do |f|
          next false unless File.exist?(f)
          # Check if tracked by git
          _, _, tracked = Open3.capture3("git ls-files --error-unmatch #{f}")
          next false unless tracked.success?
          # Check if modified or new (untracked-but-staged)
          diff_out, _, _ = Open3.capture3("git status --porcelain #{f}")
          !diff_out.strip.empty?
        end

        if files_to_commit.empty?
          puts "  ℹ️  No deploy files changed — skipping commit"
          return { success: true }
        end

        print "  📝 Committing deploy files (#{files_to_commit.join(", ")})..."
        _out, err, status = Open3.capture3(
          "git add #{files_to_commit.map { |f| "'#{f}'" }.join(" ")} && " \
          "git commit -m 'chore: prepare project for Railway deployment'"
        )

        unless status.success?
          puts " ❌"
          return hard_fail("git commit failed:\n#{err}")
        end

        puts " ✅"
        { success: true }
      end

      def step1_create_task(project_id, api_client, region: nil)
        puts "\n[Step 1] Creating deploy task..."
        result = api_client.create_task(project_id: project_id, region: region)

        unless result[:success]
          return hard_fail("Failed to create deploy task: #{result[:error]}")
        end

        puts "✅ Deploy task created: #{result[:deploy_task_id]}"
        result
      end

      def step2_railway_link(railway_token, platform_project_id)
        puts "\n[Step 2] Linking Railway project..."

        # Write .railway/config.json directly instead of running `railway link`.
        # `railway link` requires an account-level token (RAILWAY_API_TOKEN) to list
        # workspaces/projects, but we only have a Project Token (RAILWAY_TOKEN).
        # Writing the config file is exactly what `railway link` does internally, and
        # all subsequent CLI commands (up, variables, run, logs) work fine with a
        # Project Token once the project binding is in place.
        print "  📝 Writing .railway/config.json..."
        begin
          FileUtils.mkdir_p(".railway")
          config = {
            "projectId"       => platform_project_id,
            "environmentName" => "production"
          }
          File.write(".railway/config.json", JSON.generate(config))
          puts " ✅"
        rescue => e
          puts " ❌"
          return hard_fail("Failed to write .railway/config.json: #{e.message}")
        end

        # Detect main service name using RAILWAY_TOKEN (Project Token supports `railway status`)
        env = railway_env(railway_token)
        print "  🔍 Detecting service name..."
        svc_name = detect_service_name(env)
        puts " ✅ #{svc_name}"
        puts "✅ Linked to Railway project. Main service: #{svc_name}"

        { success: true, service_name: svc_name, railway_token: railway_token }
      end

      def step3_inject_env_vars(service_name, project, platform_token)
        puts "\n[Step 3] Injecting environment variables..."

        print "  ⚙️  Building env vars (generating SECRET_KEY_BASE)..."
        vars = build_env_vars(project)
        puts " ✅ (#{vars.size} vars)"

        print "  📤 Pushing env vars to Railway..."
        result = DeployTools::SetDeployVariables.execute(
          service_name:   service_name,
          variables:      vars,
          platform_token: platform_token
        )

        unless result[:success]
          puts " ❌"
          return hard_fail("Failed to set environment variables: #{result[:errors].inspect}")
        end

        puts " ✅"
        puts "✅ Set #{result[:set_variables].length} environment variable(s)"
        { success: true }
      end

      # Inject S3-compatible storage bucket credentials as STORAGE_BUCKET_* env vars.
      # Called after step4 because bucket credentials come from the services API response.
      # The bucket_credentials hash comes from platform_bucket_credentials in the API.
      #
      # Maps API fields → Railway env vars:
      #   endpoint         → STORAGE_BUCKET_ENDPOINT
      #   accessKeyId      → STORAGE_BUCKET_ACCESS_KEY_ID
      #   secretAccessKey  → STORAGE_BUCKET_SECRET_ACCESS_KEY
      #   region           → STORAGE_BUCKET_REGION + AWS_REGION
      #   bucketName       → STORAGE_BUCKET_NAME
      def step3b_inject_bucket_vars(service_name, bucket_credentials, bucket_name, platform_token)
        return unless bucket_credentials.is_a?(Hash)

        name = bucket_name.to_s.empty? ? bucket_credentials["bucketName"].to_s : bucket_name

        vars = {}
        vars["STORAGE_BUCKET_ENDPOINT"]          = bucket_credentials["endpoint"].to_s          unless bucket_credentials["endpoint"].to_s.empty?
        vars["STORAGE_BUCKET_ACCESS_KEY_ID"]     = bucket_credentials["accessKeyId"].to_s       unless bucket_credentials["accessKeyId"].to_s.empty?
        vars["STORAGE_BUCKET_SECRET_ACCESS_KEY"] = bucket_credentials["secretAccessKey"].to_s   unless bucket_credentials["secretAccessKey"].to_s.empty?
        vars["STORAGE_BUCKET_NAME"]              = name                                          unless name.empty?

        region = bucket_credentials["region"].to_s
        region = "auto" if region.empty?
        vars["STORAGE_BUCKET_REGION"] = region
        vars["AWS_REGION"]            = region

        return if vars.empty?

        puts "\n[Step 3b] Injecting storage bucket credentials (#{vars.size} vars)..."
        result = DeployTools::SetDeployVariables.execute(
          service_name:   service_name,
          variables:      vars,
          platform_token: platform_token
        )

        if result[:success]
          puts "✅ Storage bucket vars injected (STORAGE_BUCKET_*, AWS_REGION)"
        else
          puts "⚠️  Storage bucket vars partially failed: #{result[:errors].inspect}"
        end
      end

      def step4_wait_db_and_bind(deploy_task_id, service_name, api_client, platform_token)
        puts "\n[Step 4] Waiting for database service + binding domain..."

        domain_name        = nil
        db_injected        = false
        elapsed            = 0
        bucket_credentials = nil
        bucket_name        = nil

        # First call to check middleware_support — determines whether we need to poll for a DB.
        initial = api_client.services(deploy_task_id: deploy_task_id)
        if initial[:success]
          # Capture bucket credentials from the first successful response
          bucket_credentials = initial[:bucket_credentials]
          bucket_name        = initial[:bucket_name]

          # Check if Clacky will provision a DB middleware at all
          mw_support = initial[:middleware_support] || {}
          db_supported = mw_support["supported"] == true

          # Capture domain if already available on first call
          domain_name = initial[:domain_name] if !initial[:domain_name].to_s.empty?

          unless db_supported
            # No DB middleware expected — skip the entire DB polling loop
            puts "  ℹ️  No database middleware provisioned by Clacky (middleware_support: false)"
            puts "  ✅ Skipping DB wait — proceeding directly to domain binding"
            db_injected = true  # mark as done so we don't wait for it
          end
        end

        # Only poll if DB middleware is expected (middleware_support.supported == true)
        unless db_injected
          DB_POLL_MAX.times do |i|
            # Check first on iteration 0, then sleep — so already-running DB resolves instantly
            result = api_client.services(deploy_task_id: deploy_task_id)

            if result[:success]
              # Capture bucket credentials on first available result
              bucket_credentials ||= result[:bucket_credentials]
              bucket_name        ||= result[:bucket_name]

              # Inject DATABASE_URL once DB is ready
              if !db_injected && result[:db_service]
                db_svc_name = result[:db_service]["service_name"]
                db_ref      = "${{#{db_svc_name}.DATABASE_PUBLIC_URL}}"

                puts "\r  🗄️  Database ready (#{db_svc_name}), injecting DATABASE_URL...        "
                DeployTools::SetDeployVariables.execute(
                  service_name:   service_name,
                  variables:      { "DATABASE_URL" => db_ref },
                  platform_token: platform_token,
                  raw_value:      true
                )
                db_injected = true
                puts "  ✅ DATABASE_URL injected"
              end

              # Capture domain once available
              if domain_name.nil? && !result[:domain_name].to_s.empty?
                domain_name = result[:domain_name]
                puts "  ✅ Domain assigned: #{domain_name}"
              end

              break if db_injected && !domain_name.nil?
            else
              print "\r  ⚠️  services poll failed: #{result[:error]} (attempt #{i + 1}/#{DB_POLL_MAX})  "
              $stdout.flush
            end

            # Sleep before next iteration (skip sleep on last attempt)
            unless i == DB_POLL_MAX - 1
              sleep DB_POLL_INTERVAL
              elapsed += DB_POLL_INTERVAL
              print "\r  ⏳ Waiting for services... #{elapsed}s elapsed (#{i + 1}/#{DB_POLL_MAX})  "
              $stdout.flush
            end
          end
        end

        puts "" # newline after \r spinner

        # Bind domain if not returned by services API
        if domain_name.nil?
          print "  🌐 Binding domain via API..."
          bind = api_client.bind_domain(deploy_task_id: deploy_task_id)
          if bind[:success]
            domain_name = bind[:domain]
            puts " ✅ #{domain_name}"
          else
            puts " ⚠️  domain not available yet"
          end
        end

        puts "✅ Step 4 complete. Domain: #{domain_name || "(not available yet)"}"
        {
          success:            true,
          domain_name:        domain_name,
          bucket_credentials: bucket_credentials,
          bucket_name:        bucket_name
        }
      end

      def step5_trigger_build(service_name, project_id, deploy_task_id, api_client, platform_token)
        puts "\n[Step 5] Triggering build..."

        result = DeployTools::ExecuteDeployment.execute(
          service_name:   service_name,
          platform_token: platform_token
        )

        unless result[:success]
          api_client.notify(project_id: project_id, deploy_task_id: deploy_task_id, status: "failed",
                            message: result[:error])
          return hard_fail("Failed to trigger build: #{result[:error]}")
        end

        puts "✅ Build triggered"
        api_client.notify(project_id: project_id, deploy_task_id: deploy_task_id, status: "deploying")
        { success: true }
      end

      def step6_monitor_status(deploy_task_id, project_id, deploy_service_id, api_client,
                               service_name, platform_token)
        puts "\n[Step 6] Monitoring deployment status..."

        elapsed = 0
        dots    = 0

        DEPLOY_POLL_MAX.times do |i|
          sleep DEPLOY_POLL_INTERVAL
          elapsed += DEPLOY_POLL_INTERVAL
          dots    += 1

          result = api_client.deploy_status(deploy_task_id: deploy_task_id)

          unless result[:success]
            print "\r  ⏳ Deploying#{"." * (dots % 4 + 1)}   #{elapsed}s elapsed (polling...)       "
            $stdout.flush
            next
          end

          case result[:status]
          when "SUCCESS"
            puts "\r  ✅ Deployment succeeded! (#{elapsed}s)                              "
            return { success: true, url: result[:url] }
          when "FAILED", "CRASHED", "ERROR"
            puts "\r  ❌ Deployment #{result[:status]} (#{elapsed}s)                      "
            show_build_logs(service_name, platform_token)
            api_client.notify(project_id: project_id, deploy_task_id: deploy_task_id,
                              status: "failed", message: "Deploy status: #{result[:status]}")
            return hard_fail("Deployment failed with status: #{result[:status]}")
          else
            current_status = result[:status].to_s.empty? ? "building" : result[:status].downcase
            print "\r  ⏳ Deploying#{". " * (dots % 4 + 1)}  #{elapsed}s elapsed [#{current_status}]       "
            $stdout.flush
          end
        end

        puts "\n"
        api_client.notify(project_id: project_id, deploy_task_id: deploy_task_id,
                          status: "failed", message: "Deployment timed out")
        hard_fail("Deployment timed out after #{DEPLOY_POLL_MAX * DEPLOY_POLL_INTERVAL} seconds.")
      end

      def step7_run_migrations(service_name, platform_token)
        puts "\n[Step 7] Running database migrations..."
        env = railway_env(platform_token)

        # If railway.toml has preDeployCommand = "bundle exec rails db:migrate",
        # migrations already ran inside the deploy container — skip redundant railway run.
        if pre_deploy_migrate_configured?
          puts "  ⚡ preDeployCommand detected — db:migrate ran automatically during deploy"
          puts "  ✅ Skipping redundant migration step (~30s saved)"
        else
          # No preDeployCommand — run migrations explicitly
          print "  🗄️  Running db:migrate (this may take ~30s)..."
          migrate_cmd = "railway run --service #{shell_escape(service_name)} bundle exec rails db:migrate"
          out, err, status = Open3.capture3(env, migrate_cmd)

          if status.success?
            puts " ✅"
            puts out unless out.strip.empty?
          else
            puts " ⚠️"
            puts "⚠️  Migration warning (continuing): #{err}"
          end
        end

        # Seed detection: only on first deployment (no preDeployCommand equivalent for seeds)
        print "  🔍 Checking if db:seed is needed..."
        is_first = first_deployment?(service_name, env)

        if is_first
          puts " ✅ First deployment — running db:seed"
          print "  🌱 Running db:seed..."
          seed_cmd = "railway run --service #{shell_escape(service_name)} bundle exec rails db:seed"
          out, _err, _status = Open3.capture3(env, seed_cmd)
          puts " ✅"
          puts out unless out.strip.empty?
        else
          puts " ✅ Update deployment — skipping db:seed"
        end

        puts "✅ Step 7 complete"
        { success: true }
      end

      def step8_finish(domain_name, project_id, deploy_task_id, deploy_service_id, api_client)
        puts "\n[Step 8] Finalising deployment..."

        app_url  = domain_name ? "https://#{domain_name.sub(/\Ahttps?:\/\//, "")}" : nil
        dash_url = "#{@dashboard_base_url}/#{project_id}"

        # Notify success immediately — don't block on health check
        api_client.notify(
          project_id:        project_id,
          deploy_task_id:    deploy_task_id,
          deploy_service_id: deploy_service_id,
          status:            "success",
          target_port:       3000
        )

        # Print success banner right away so user sees the URL without waiting
        puts "\n" + "=" * 60
        puts "✅ DEPLOYMENT SUCCESSFUL"
        puts "=" * 60
        puts "🌐 URL       : #{app_url || "(not available)"}"
        puts "📊 Dashboard : #{dash_url}"
        puts "=" * 60

        # Health check runs after banner — non-fatal, purely informational
        if app_url
          puts "\n🏥 Running health check (non-blocking)..."
          health_passed = false
          3.times do |i|
            result = DeployTools::CheckHealth.execute(url: app_url, timeout: 30)
            if result[:success]
              puts "✅ App is live! Health check passed (HTTP #{result[:status_code]})"
              health_passed = true
              break
            else
              puts "  ⚠️  Health check #{i + 1}/3: #{result[:error]}"
              sleep 10 unless i == 2
            end
          end
          puts "  ℹ️  App may still be warming up — visit the URL in a moment." unless health_passed
        end

        puts ""
        { success: true, url: app_url || "(not available)", dashboard_url: dash_url }
      end

      # -----------------------------------------------------------------------
      # Utility helpers
      # -----------------------------------------------------------------------

      def platform_already_present?(lock_content, platform)
        # Gemfile.lock PLATFORMS section looks like:
        #   PLATFORMS
        #     arm64-darwin-23
        #     x86_64-linux
        in_platforms = false
        lock_content.each_line do |line|
          if line.strip == "PLATFORMS"
            in_platforms = true
            next
          end
          # A non-indented line signals the end of the PLATFORMS block
          break if in_platforms && !line.start_with?(" ")
          return true if in_platforms && line.strip == platform
        end
        false
      end

      def railway_cli_available?
        system("which railway > /dev/null 2>&1")
      end

      def railway_env(platform_token)
        ENV.to_h.merge("RAILWAY_TOKEN" => platform_token)
      end

      def detect_service_name(env)
        # 1. Try railway.toml [service] name field
        toml = "railway.toml"
        if File.exist?(toml)
          content = File.read(toml)
          m = content.match(/\[service\][^\[]*name\s*=\s*["']?([^"'\n]+)["']?/m)
          return m[1].strip if m
        end

        # 2. Use railway status --json to find the linked service
        out, _err, status = Open3.capture3(env, "railway status --json")
        if status.success?
          begin
            info = JSON.parse(out)
            # Railway v4 status JSON uses edges/node format:
            # { "services": { "edges": [ { "node": { "id": "...", "name": "..." } } ] } }
            # Older format was: { "services": [ { "name": "..." } ] }
            raw_svcs = info["services"]
            svcs = if raw_svcs.is_a?(Hash) && raw_svcs["edges"]
                     raw_svcs["edges"].map { |e| e["node"] }.compact
                   elsif raw_svcs.is_a?(Array)
                     raw_svcs
                   else
                     []
                   end

            svc = svcs.find do |s|
              name = s["name"].to_s.downcase
              !%w[postgres postgresql mysql redis].any? { |db| name.include?(db) }
            end
            return svc["name"] if svc
          rescue JSON::ParserError
            # fall through
          end
        end

        # 3. Fallback to directory name
        File.basename(Dir.pwd)
      end

      def build_env_vars(project)
        vars = {
          "RAILS_ENV"                 => "production",
          "RAILS_SERVE_STATIC_FILES"  => "true",
          "RAILS_LOG_TO_STDOUT"       => "true",
          "RAILWAY_RUN_UID"           => "0"
        }

        # Generate SECRET_KEY_BASE
        secret = generate_secret_key_base
        vars["SECRET_KEY_BASE"] = secret if secret

        # Figaro: parse config/application.yml (ERB-rendered).
        # This already contains the CLACKY_* integration vars written by /new,
        # so we don't need to inject categorized_config separately.
        figaro_vars = parse_figaro_production
        if figaro_vars.any?
          vars.merge!(figaro_vars)
        else
          # Fallback: inject categorized_config directly if no application.yml
          vars.merge!(extract_categorized_config(project["categorized_config"]))
        end

        vars
      end

      def generate_secret_key_base
        out, _err, status = Open3.capture3("bundle exec rails secret")
        return out.strip if status.success? && !out.strip.empty?
        # Fallback: generate a cryptographically secure key using SecureRandom
        require "securerandom"
        SecureRandom.hex(64)
      rescue
        require "securerandom"
        SecureRandom.hex(64)
      end

      def parse_figaro_production
        app_yml = "config/application.yml"
        return {} unless File.exist?(app_yml)

        require "erb"
        # Must ERB-render first: application.yml typically contains <%= ENV.fetch(...) %>
        raw      = File.read(app_yml)
        rendered = ERB.new(raw).result
        data     = YAML.safe_load(rendered) || {}

        # Figaro stores all vars at the top level (no "production:" block).
        # Skip blank values — those are placeholders to be filled by the user.
        data.each_with_object({}) do |(k, v), h|
          next if v.to_s.strip.empty?
          h[k.to_s] = v.to_s
        end
      rescue => e
        warn "[deploy] parse_figaro_production error: #{e.message}"
        {}
      end

      def extract_categorized_config(categorized_config)
        return {} unless categorized_config.is_a?(Hash)

        categorized_config.each_with_object({}) do |(_category, vars), h|
          next unless vars.is_a?(Hash)
          vars.each { |k, v| h[k.to_s] = v.to_s }
        end
      end

      def pre_deploy_migrate_configured?
        toml_path = "railway.toml"
        return false unless File.exist?(toml_path)
        content = File.read(toml_path)
        content.include?("preDeployCommand") && content.include?("db:migrate")
      end

      def first_deployment?(service_name, env)
        # Check 1: can we connect to the DB at all?
        check1_cmd = "railway run --service #{shell_escape(service_name)} " \
                     "bundle exec rails runner \"ActiveRecord::Base.connection; puts 'connected'\""
        _out, _err, status1 = Open3.capture3(env, check1_cmd)
        return true unless status1.success?

        # Check 2: any migrations recorded?
        check2_cmd = "railway run --service #{shell_escape(service_name)} " \
                     "bundle exec rails db:migrate:status 2>&1"
        out2, _err2, _status2 = Open3.capture3(env, check2_cmd)

        # If no schema_migrations entries exist, output mentions "up" lines
        !out2.match?(/^\s*(up|down)\s+\d{14}/)
      rescue
        false
      end

      def show_build_logs(service_name, platform_token)
        puts "\n📋 Last build log lines:"
        puts "-" * 40

        env = railway_env(platform_token)
        cmd = "railway logs --build --lines 30 --service #{shell_escape(service_name)}"
        out, err, _status = Open3.capture3(env, cmd)

        output = out.empty? ? err : out
        output.each_line { |line| puts "  #{line.chomp}" }

        puts "-" * 40
      end

      def open_browser(url)
        case RbConfig::CONFIG["host_os"]
        when /darwin/  then system("open #{shell_escape(url)}")
        when /linux/   then system("xdg-open #{shell_escape(url)}")
        when /mingw|mswin/ then system("start #{shell_escape(url)}")
        end
      end

      def shell_escape(str)
        "'#{str.to_s.gsub("'", "'\\\\''")}'"
      end

      def hard_fail(message)
        puts "\n❌ #{message}"
        { success: false, error: message }
      end

      def print_banner
        puts "\n" + "=" * 60
        puts "🚂 Clacky Rails Deploy"
        puts "=" * 60
      end
    end
  end
end

# Run when executed directly
if __FILE__ == $PROGRAM_NAME
  result = Clacky::DeployTemplates::RailsDeploy.execute
  exit(result[:success] ? 0 : 1)
end
