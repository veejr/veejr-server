import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Route federation HTTP through Req.Test so tests can stub remote instances.
config :veejr, :federation_req_options, plug: {Req.Test, Veejr.FederationStub}

# Route release-update checks through Req.Test as well.
config :veejr, :updates_req_options, plug: {Req.Test, Veejr.UpdatesStub}

# The outbox never ticks (or reacts to kicks) on its own in tests;
# process_due/0 is driven directly.
config :veejr, :outbox_tick_ms, :never

# The janitor never sweeps on its own in tests; purge_abandoned_blobs/0 is
# driven directly.
config :veejr, :janitor_interval_ms, :never

# Scheduled-call reminders are driven directly in tests.
config :veejr, :call_reminder_interval_ms, :never

# Scheduled message release and note reminders are driven directly in tests;
# a background sweep would race the DB sandbox.
config :veejr, :message_schedule_interval_ms, :never

# No deferred hang-up tasks in tests (they would outlive the DB sandbox);
# presence and end_call are exercised directly.
config :veejr, :call_grace_ms, :never

# Presence never heartbeats or expires remotes on its own in tests: the sweep
# would outlive the DB sandbox and race every other test. The federated tests
# drive Veejr.Presence.tick/0 directly.
config :veejr, :presence_heartbeat_ms, :never

# Nor does it post presence to peers on its own. The detached HTTP task would
# outlive the Req.Test stub that is scoped to the test process, so the two
# halves of the seam are driven directly: Veejr.Presence.peer_deliveries/1 for
# the addressing, Veejr.Federation.deliver_presence/2 for the request.
config :veejr, :presence_federation, false

# Every test request arrives from 127.0.0.1 and would share one bucket, so
# the budgets are raised out of the way here. Tests that exercise limiting set
# their own limits via Veejr.RateLimiter.check/4, or override a bucket for the
# duration of one test. The limiter itself stays enabled so the plugs, the
# router wiring, and the LiveView call sites are all exercised normally.
config :veejr, :rate_limits,
  enabled: true,
  login: {1_000_000, :timer.minutes(1)},
  magic_link: {1_000_000, :timer.minutes(1)},
  registration: {1_000_000, :timer.minutes(1)},
  directory: {1_000_000, :timer.minutes(1)},
  invitation: {1_000_000, :timer.minutes(1)},
  upload: {1_000_000, :timer.minutes(1)},
  federation: {1_000_000, :timer.minutes(1)},
  federation_presence: {1_000_000, :timer.minutes(1)}

# No spontaneous Web Push sends from tests; Veejr.Push.notify/1 is called directly.
config :veejr, :push_enabled, false
config :veejr, :push_req_options, plug: {Req.Test, Veejr.PushStub}

# Keep test attachment blobs out of priv/
config :veejr, :blob_dir, Path.join(System.tmp_dir!(), "veejr_test_uploads")

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :veejr, Veejr.Repo,
  database: Path.expand("../veejr_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :veejr, VeejrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tqctDDi1niKiwixpKaD9yGHOmXRMgTLMLGrvKfk0gq/lBuCiZ2+qtxz8Qe9Xl5JG",
  server: false

# In test we don't send emails
config :veejr, Veejr.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
