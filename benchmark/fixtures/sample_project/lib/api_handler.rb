# frozen_string_literal: true

module SampleProject
  class ApiHandler
    def initialize(store)
      @store = store
    end

    def handle_request(path, params)
      case path
      when "/users"
        list_users(params)
      when "/orders"
        list_orders(params)
      else
        { error: "Not found", status: 404 }
      end
    end

    private

    def list_users(params)
      users = @store.query("SELECT * FROM users LIMIT #{params[:limit] || 10}")
      { data: users, status: 200 }
    end

    def list_orders(params)
      orders = @store.all(:orders)
      { data: orders, status: 200 }
    end
  end
end
