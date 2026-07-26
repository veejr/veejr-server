defmodule Veejr.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VeejrWeb.Telemetry,
      Veejr.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:veejr, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:veejr, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Veejr.PubSub},
      # One ephemeral, host-controlled YouTube watch party per instance.
      {Veejr.WatchParties, []},
      # Retries federation deliveries to unreachable instances.
      {Veejr.Federation.Outbox, []},
      # Persists and retries browser and Android push delivery.
      {Veejr.Push.Outbox, []},
      # Dispatches persistent scheduled-call reminders.
      {Veejr.Calls.Reminders, []},
      # Periodic cleanup (abandoned attachment uploads, stale calls).
      {Veejr.Janitor, []},
      # Live presence of call participants (which tabs sit on a call page),
      # so brief socket reconnects don't hang calls up.
      {Registry, keys: :duplicate, name: Veejr.CallRegistry},
      {Task.Supervisor, name: Veejr.TaskSupervisor},
      # Start to serve requests, typically the last entry
      VeejrWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Veejr.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VeejrWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Releases always migrate at boot. The source-mounted prod deployment
    # opts in via :auto_migrate (set in prod.exs) so a restart into a newer
    # checkout — including the in-app self-upgrade — migrates itself with
    # its own freshly compiled modules. Dev and test migrate explicitly.
    cond do
      System.get_env("RELEASE_NAME") -> false
      Application.get_env(:veejr, :auto_migrate, false) -> false
      true -> true
    end
  end
end
