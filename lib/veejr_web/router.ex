defmodule VeejrWeb.Router do
  use VeejrWeb, :router

  import VeejrWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VeejrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # After put_secure_browser_headers so the policy (and its per-response
    # nonce) is not overwritten by the default header set.
    plug VeejrWeb.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_api_user do
    plug VeejrWeb.ApiAuth
  end

  pipeline :federation do
    plug :accepts, ["json"]
    # Budget before signature verification: an unauthenticated flood should
    # not get to spend Ed25519 verifications.
    plug VeejrWeb.Plugs.RateLimit, bucket: :federation, by: :federation_authority
    plug VeejrWeb.FederationAuth
  end

  pipeline :provisioner do
    plug :accepts, ["json"]
    plug VeejrWeb.ProvisionerAuth
  end

  # Per-surface request budgets required by REIMPLEMENTATION_SPEC.md §17.
  # Each rejects with 429 + Retry-After; see VeejrWeb.Plugs.RateLimit.
  pipeline :limit_login do
    plug VeejrWeb.Plugs.RateLimit, bucket: :login
  end

  pipeline :limit_magic_link do
    plug VeejrWeb.Plugs.RateLimit, bucket: :magic_link
  end

  pipeline :limit_directory do
    plug VeejrWeb.Plugs.RateLimit, bucket: :directory
  end

  pipeline :limit_upload do
    plug VeejrWeb.Plugs.RateLimit, bucket: :upload
  end

  scope "/api/provisioner/v1", VeejrWeb do
    pipe_through :provisioner

    post "/jobs/claim", ProvisionerController, :claim
    get "/moves/:public_id/package", ProvisionerController, :package
    post "/moves/:public_id/result", ProvisionerController, :result
  end

  scope "/", VeejrWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/avatars/:username", AvatarController, :show
  end

  # Public instance API: the surface other veejr instances (and curious
  # humans) can query without authentication.
  scope "/api", VeejrWeb do
    pipe_through :api

    get "/instance", InstanceController, :instance

    # Capability URL: the unguessable id (delivered only to the recipient's
    # instance) is the credential, and the content is E2E ciphertext.
    get "/envelopes/:public_id", FederationController, :envelope
  end

  # Directory lookups publish a local user's public key and display name, so
  # an unbudgeted endpoint enumerates the instance's whole membership.
  scope "/api", VeejrWeb do
    pipe_through [:api, :limit_directory]

    get "/directory/:username", InstanceController, :directory
  end

  scope "/api/v1", VeejrWeb.Api.V1 do
    pipe_through :api

    get "/capabilities", CapabilitiesController, :show
  end

  scope "/api/v1", VeejrWeb.Api.V1 do
    pipe_through [:api, :limit_login]

    post "/auth/login", AuthController, :login
    post "/auth/refresh", AuthController, :refresh
  end

  # Magic-link requests send mail to an address the caller names, so these
  # carry a tighter budget than password attempts.
  scope "/api/v1", VeejrWeb.Api.V1 do
    pipe_through [:api, :limit_magic_link]

    post "/auth/magic-link", AuthController, :request_magic_link
    post "/auth/magic-link/exchange", AuthController, :exchange_magic_link
  end

  scope "/api/v1", VeejrWeb.Api.V1 do
    pipe_through [:api, :require_api_user]

    delete "/auth/session", AuthController, :logout
    put "/devices/current/push-token", AuthController, :register_push_token
    delete "/devices/current/push-token", AuthController, :delete_push_token
    get "/me", MeController, :show
    put "/keys", KeysController, :create
    get "/notifications", NotificationController, :index
    post "/notifications/:id/accept", NotificationController, :accept
    post "/notifications/:id/decline", NotificationController, :decline
    get "/contacts", RecipientController, :index
    put "/contacts/:id/note", RecipientController, :note
    get "/groups", GroupController, :index
    put "/groups/:id/note", GroupController, :note
    post "/recipients/resolve", RecipientController, :resolve
    post "/message-batches", MessageBatchController, :create
    get "/envelopes", EnvelopeController, :index
    get "/message-delivery-policies", MessageDeliveryPolicyController, :index
    put "/contacts/:subject_id/message-delivery-policy", MessageDeliveryPolicyController, :contact

    delete "/contacts/:subject_id/message-delivery-policy",
           MessageDeliveryPolicyController,
           :delete_contact

    put "/groups/:subject_id/message-delivery-policy", MessageDeliveryPolicyController, :group

    delete "/groups/:subject_id/message-delivery-policy",
           MessageDeliveryPolicyController,
           :delete_group

    put "/conversations/:subject_id/message-delivery-policy",
        MessageDeliveryPolicyController,
        :conversation

    delete "/conversations/:subject_id/message-delivery-policy",
           MessageDeliveryPolicyController,
           :delete_conversation
  end

  scope "/api/v1", VeejrWeb.Api.V1 do
    pipe_through [:api, :require_api_user, :limit_upload]

    post "/blobs", BlobController, :create
  end

  # Public attachment capability. No pipeline: serves opaque octet-stream
  # bytes (not JSON) to a recipient's browser, which may be on another
  # instance. The blob id is an unguessable capability and the content is
  # E2E-encrypted; see BlobController.public_show/2.
  scope "/api", VeejrWeb do
    get "/blobs/:id", BlobController, :public_show
  end

  # Instance-to-instance writes require a valid signature from a pinned peer.
  scope "/api/federation", VeejrWeb do
    pipe_through :federation

    post "/friend_request", FederationController, :friend_request
    post "/friend_response", FederationController, :friend_response
    post "/notify", FederationController, :notify
    post "/key_update", FederationController, :key_update
    post "/account_move", FederationController, :account_move
    post "/call_invite", FederationController, :call_invite
    post "/call_update", FederationController, :call_update
    post "/call_signal", FederationController, :call_signal
    post "/call_schedule", FederationController, :call_schedule
    post "/presence", FederationController, :presence
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:veejr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VeejrWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", VeejrWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{VeejrWeb.UserAuth, :require_authenticated}, VeejrWeb.TrackPresence] do
      live "/account", UserLive.Account, :index
      live "/admin", AdminLive, :index
      live "/account/archives", UserLive.Archives, :index
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/keys", KeysLive
    end

    live_session :app,
      on_mount: [
        {VeejrWeb.UserAuth, :require_authenticated},
        {VeejrWeb.KeyGate, :ensure_keys},
        {VeejrWeb.ClientIp, :default},
        VeejrWeb.TrackPresence,
        VeejrWeb.LiveNotify
      ] do
      live "/friends", FriendsLive
      live "/groups", GroupsLive
      live "/contacts", ContactsLive
      live "/invites/new", InvitationLive.New, :new
      live "/guest-conferences/new", GuestConferenceLive.New, :new
      live "/guest-conferences/:public_id", GuestConferenceLive.Host, :show
      live "/guest-conferences/:public_id/call", GuestConferenceLive.HostCall, :show
      live "/messages", MessagesLive
      live "/map", MapLive
      live "/history", HistoryLive
      live "/watch", WatchLive, :new
      live "/watch/:public_id", WatchLive, :show
      live "/calls", CallsLive
      live "/call/:public_id", CallLive
    end

    post "/users/update-password", UserSessionController, :update_password
    get "/avatar-textures/:id", AvatarController, :texture
    get "/blobs/:id", BlobController, :show
    get "/export", ExportController, :download
    post "/push/subscriptions", PushController, :create
    delete "/push/subscriptions", PushController, :delete
  end

  # Encrypted attachment and avatar uploads: authenticated, but still the
  # cheapest way for one account to consume an instance's disk.
  scope "/", VeejrWeb do
    pipe_through [:browser, :require_authenticated_user, :limit_upload]

    post "/blobs", BlobController, :create
    post "/account/avatar", AvatarController, :create
  end

  scope "/", VeejrWeb do
    pipe_through [:browser]

    live_session :guest_conference do
      live "/guest/:token", GuestConferenceLive.Guest, :show
      live "/guest/:token/call", GuestConferenceLive.Call, :show
    end

    live_session :guest_watch_party do
      live "/watch/guest/:token", GuestWatchLive, :show
    end

    live_session :current_user,
      on_mount: [{VeejrWeb.UserAuth, :mount_current_scope}, {VeejrWeb.ClientIp, :default}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", VeejrWeb do
    pipe_through [:browser, :limit_login]

    post "/users/log-in", UserSessionController, :create
  end
end
