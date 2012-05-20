module I18nBackendDatabase
  class Engine < Rails::Engine
    initializer "common.init" do |app|
      # Publish #{root}/public path so it can be included at the app level
      if app.config.serve_static_assets
        app.config.middleware.use ::ActionDispatch::Static, "#{root}/public"
      end
    end
  end
end
