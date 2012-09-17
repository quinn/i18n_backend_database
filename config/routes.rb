Rails.application.routes.draw do
  resources :locales do 
    resources :translations
  end
  match '/translations' => 'translations#translations', :as => 'translations'
  match '/asset_translations' => 'translations#asset_translations', :as => 'asset_translations'
end
