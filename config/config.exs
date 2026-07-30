# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :veejr, :scopes,
  user: [
    default: true,
    module: Veejr.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Veejr.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :veejr,
  ecto_repos: [Veejr.Repo],
  generators: [timestamp_type: :utc_datetime],
  migration_dir: Path.expand("../priv/migrations", __DIR__),
  # GitHub owner/repo consulted for release updates; forks point at their own.
  update_repo: "veejr/veejr-server",
  # WebRTC ICE servers for calls; override per deployment in runtime.exs.
  ice_servers: [%{urls: ["stun:stun.l.google.com:19302"]}],
  provisioner_token: nil,
  # :community (open registration) or :personal (single-owner instance)
  instance_mode: :community,
  mail_from: {"Veejr", "hello@example.invalid"}

# Configure the endpoint
config :veejr, VeejrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: VeejrWeb.ErrorHTML, json: VeejrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Veejr.PubSub,
  live_view: [signing_salt: "K+hL8Jee"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :veejr, Veejr.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
# `--splitting --format=esm` is what makes `await import(…)` produce a separate
# chunk instead of being inlined into app.js. Without it esbuild bundles a
# dynamic import into the entry point and the on-demand editors (spreadsheet,
# word processor) would cost every session their bytes. It requires the entry
# to be loaded as `<script type="module">`; see root.html.heex.
config :esbuild,
  version: "0.25.4",
  veejr: [
    args:
      ~w(js/app.js --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --chunk-names=chunks/[name]-[hash] --external:/fonts/* --external:/images/* --external:crypto --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  veejr: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Per-surface request budgets as {max_requests, window_ms}, enforced by
# Veejr.RateLimiter. Sized so a real person never reaches one; operators who
# front an instance with their own limiter can set `enabled: false`.
config :veejr, :rate_limits,
  enabled: true,
  login: {10, :timer.minutes(1)},
  magic_link: {5, :timer.minutes(5)},
  registration: {5, :timer.hours(1)},
  directory: {60, :timer.minutes(1)},
  invitation: {20, :timer.hours(1)},
  upload: {60, :timer.minutes(1)},
  federation: {120, :timer.minutes(1)}

# Reverse proxies whose x-forwarded-for header may be believed. Defaults to
# loopback and private ranges, which is what a same-host or container proxy
# (Caddy, in the project deployment) connects from. See Veejr.RemoteIp.
config :veejr, :trusted_proxies, [
  "127.0.0.0/8",
  "::1/128",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "192.168.0.0/16",
  "169.254.0.0/16",
  "fc00::/7",
  "fe80::/10"
]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
