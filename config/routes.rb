Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest, defaults: { format: :json }

  # Defines the root path route ("/")
  root "dashboard#show"

  get "sign_up" => "users#new"
  post "sign_up" => "users#create"
  get "sign_in" => "sessions#new"
  post "sign_in" => "sessions#create"
  delete "sign_out" => "sessions#destroy"

  resource :password, only: %i[edit update]

  resources :transactions, only: %i[index show new create update] do
    collection { get :duplicates; patch :bulk_update; post :classify; post :categorize }
    member { post :split; delete :unsplit }
  end
  resources :categories, only: %i[index edit create update] do
    member { post :merge; patch :expense_type }
  end
  resources :transaction_rules, only: %i[index edit create update destroy]
  resources :budgets, only: %i[index create update destroy]
  get "trends" => "trends#show", as: :trends
  resources :recurring_items, path: "recurring", except: :show do
    collection { post :dismiss; delete "dismissals/:id", action: :restore_suggestion, as: :restore_suggestion }
  end
  resources :manual_assets, path: "my-assets", only: %i[index new create edit update]

  get "bank_connections/new" => "bank_connections#new", as: :new_bank_connection
  resources :imports, only: %i[new create show update]
  post "plaid_items/refresh_stale" => "plaid_items#refresh_stale", as: :refresh_stale_plaid_items
  patch "plaid_items/:id/tracking" => "plaid_items#tracking", as: :tracking_plaid_item
  post "plaid_items/:id/sync" => "plaid_items#sync", as: :sync_plaid_item

  namespace :api do
    namespace :v1 do
      post "plaid/link_token" => "plaid#link_token"
      post "plaid/exchange_public_token" => "plaid#exchange_public_token"
      post "plaid/items/:id/sync" => "plaid#sync_item"
    end
  end
end
