# frozen_string_literal: true

module SampleProject
  class UserRenderer
    def self.render_profile(user)
      <<~HTML
        <div class="profile">
          <h1>#{user[:name]}</h1>
          <p>#{user[:bio]}</p>
          <a href="#{user[:website]}">Website</a>
        </div>
      HTML
    end

    def self.render_list(users)
      items = users.map { |u| "<li>#{u[:name]}</li>" }.join
      "<ul>#{items}</ul>"
    end
  end
end
