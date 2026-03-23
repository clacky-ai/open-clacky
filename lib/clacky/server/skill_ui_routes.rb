# frozen_string_literal: true

module Clacky
  # SkillUiRouter — DSL used by skill UI routes.rb files to register API routes.
  #
  # Each skill's ui/routes.rb is evaluated via instance_eval on a SkillUiRouter instance.
  # Registered routes are stored in the HttpServer's _skill_ui_routes table and matched
  # on every incoming request after the built-in routes fail to match.
  #
  # Usage in skill's ui/routes.rb:
  #   get("/api/my-skill/items") { |req, res, _| ... }
  #   post("/api/my-skill/items") { |req, res, _| ... }
  #   get(%r{^/api/my-skill/items/([^/]+)$}) { |req, res, captures| id = captures[0]; ... }
  #
  # The handler block is instance_exec'd on the HttpServer, giving access to all
  # server helpers: json_response, parse_json_body, build_session, @registry, etc.
  class SkillUiRouter
    def initialize(server)
      @server = server
    end

    def get(pattern, &block)    = _register("GET",    pattern, block)
    def post(pattern, &block)   = _register("POST",   pattern, block)
    def delete(pattern, &block) = _register("DELETE", pattern, block)
    def patch(pattern, &block)  = _register("PATCH",  pattern, block)
    def put(pattern, &block)    = _register("PUT",    pattern, block)

    private def _register(method, pattern, block)
      server = @server
      # Wrap the block so it is always instance_exec'd on the HttpServer,
      # regardless of the lexical self where the block was defined.
      wrapped = proc { |req, res, captures| server.instance_exec(req, res, captures, &block) }
      @server._skill_ui_routes << { method: method, pattern: pattern, handler: wrapped }
    end
  end

  # SkillUiRoutes — mixin included into HttpServer to add skill UI extension support.
  #
  # Provides:
  #   - GET  /api/ui-extensions               → list all skill UIs
  #   - GET  /api/ui-extensions/:id/assets/:f → serve asset files
  #   - Dynamic routes registered via each skill's ui/routes.rb
  #
  # Included as a module so changes here never conflict with upstream http_server.rb edits.
  module SkillUiRoutes
    # Asset filenames that may be served from a skill UI directory.
    # Anything outside this list is blocked for security.
    SKILL_UI_ASSET_ALLOWED = %w[sidebar.html panel.html index.js].freeze

    # Called once on server boot to load routes from all skill ui/routes.rb files.
    # Invoke this from HttpServer#initialize after the registry is ready.
    def load_skill_ui_routes
      loader = Clacky::UiExtensionLoader.new
      loader.load_all.each do |ext|
        routes_path = File.join(ext[:dir], "routes.rb")
        next unless File.exist?(routes_path)

        router = Clacky::SkillUiRouter.new(self)
        begin
          routes_code = File.read(routes_path)
          router.instance_eval(routes_code, routes_path)
        rescue StandardError => e
          warn "[SkillUiRouter] Failed to load routes for '#{ext[:id]}': #{e.message}"
        end
      end
    end

    # Registered skill UI route table: [{ method:, pattern:, handler: }]
    # Must be public so SkillUiRouter can append routes from outside.
    def _skill_ui_routes
      @_skill_ui_routes ||= []
    end

    # Match an incoming request against registered skill UI routes.
    # Returns a callable lambda if matched, nil otherwise.
    def match_skill_ui_route(method, path)
      _skill_ui_routes.each do |route|
        next unless route[:method] == method

        captures = case route[:pattern]
                   when String then route[:pattern] == path ? [] : nil
                   when Regexp
                     m = path.match(route[:pattern])
                     m ? m.captures : nil
                   end
        return ->(req, res) { route[:handler].call(req, res, captures) } if captures
      end
      nil
    end

    # GET /api/ui-extensions
    # Returns all UI extensions found in ~/.clacky/skills/*/ui/.
    # Skills without a ui/manifest.yml are skipped.
    def api_list_skill_uis(res)
      loader    = Clacky::UiExtensionLoader.new
      skill_uis = loader.load_all.map { |p| p.reject { |k, _| k == :dir } }
      json_response(res, 200, { ui_extensions: skill_uis })
    end

    # GET /api/ui-extensions/:id/assets/:filename
    # Serve a UI extension asset (sidebar.html, panel.html, index.js).
    def api_skill_ui_asset(skill_id, filename, res)
      unless SKILL_UI_ASSET_ALLOWED.include?(filename)
        res.status = 403
        res.body   = "Forbidden"
        return
      end

      loader = Clacky::UiExtensionLoader.new
      ext    = loader.load_all.find { |e| e[:id] == skill_id }
      unless ext
        res.status = 404
        res.body   = "Skill UI not found"
        return
      end

      filepath = File.join(ext[:dir], filename)
      unless File.exist?(filepath)
        res.status = 404
        res.body   = "Asset not found"
        return
      end

      content_type = filename.end_with?(".js") ? "application/javascript; charset=utf-8" \
                                               : "text/html; charset=utf-8"
      res.status           = 200
      res["Content-Type"]  = content_type
      res["Cache-Control"] = "no-store"
      res.body             = File.read(filepath)
    end
  end
end
