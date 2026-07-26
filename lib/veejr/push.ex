defmodule Veejr.Push do
  @moduledoc """
  Browser push subscriptions and delivery.

  Each device/browser that opts in registers a `PushSubscription`; when an
  encrypted item arrives, every subscription of the recipient gets a
  content-free push ("@bob sent you an encrypted message") so the pull model
  survives even with the tab closed. Dead subscriptions (404/410 from the
  push service) are pruned automatically.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Veejr.Accounts.User
  alias Veejr.Accounts.ApiDeviceSession
  alias Veejr.Messaging.Notification
  alias Veejr.Push.AndroidPush
  alias Veejr.Push.WebPush
  alias Veejr.Repo
  alias Veejr.Social.Address

  defmodule Subscription do
    use Ecto.Schema

    schema "push_subscriptions" do
      belongs_to :user, Veejr.Accounts.User
      field :endpoint, :string
      field :p256dh, :string
      field :auth, :string

      timestamps(type: :utc_datetime)
    end
  end

  defmodule Delivery do
    use Ecto.Schema

    schema "push_deliveries" do
      field :channel, :string
      field :attempts, :integer, default: 0
      field :next_attempt_at, :utc_datetime
      field :last_error, :string
      belongs_to :notification, Notification
      belongs_to :push_subscription, Subscription
      belongs_to :api_device_session, ApiDeviceSession

      timestamps(type: :utc_datetime)
    end
  end

  @doc "Registers (or refreshes) a browser subscription for the user."
  def subscribe(%User{} = user, %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      })
      when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    %Subscription{}
    |> Ecto.Changeset.change(user_id: user.id, endpoint: endpoint, p256dh: p256dh, auth: auth)
    |> Ecto.Changeset.unique_constraint(:endpoint)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def subscribe(_user, _params), do: {:error, :invalid_subscription}

  def unsubscribe(%User{id: user_id}, endpoint) do
    from(s in Subscription, where: s.user_id == ^user_id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def subscription_count(%User{id: user_id}) do
    from(s in Subscription, where: s.user_id == ^user_id) |> Repo.aggregate(:count)
  end

  @doc "Returns the number of Android devices with an FCM token registered for `user`."
  def android_registration_count(%User{id: user_id}) do
    from(s in ApiDeviceSession,
      where: s.user_id == ^user_id and not is_nil(s.push_token)
    )
    |> Repo.aggregate(:count)
  end

  def register_android_token(%User{id: user_id}, session_id, token) when is_binary(token) do
    now = DateTime.utc_now(:second)

    from(session in ApiDeviceSession,
      where: session.id == ^session_id and session.user_id == ^user_id
    )
    |> Repo.update_all(set: [push_token: token, push_token_updated_at: now, updated_at: now])
    |> case do
      {1, _} -> :ok
      _ -> {:error, :not_found}
    end
  end

  def remove_android_token(%User{id: user_id}, session_id) do
    from(session in ApiDeviceSession,
      where: session.id == ^session_id and session.user_id == ^user_id
    )
    |> Repo.update_all(set: [push_token: nil, push_token_updated_at: nil])

    :ok
  end

  @doc """
  Pushes a content-free alert for a new notification to all of the
  recipient's devices. Called async from the messaging path.
  """
  def notify(%{id: id} = notification) when not is_nil(id) do
    now = DateTime.utc_now(:second)

    subscriptions =
      from(s in Subscription, where: s.user_id == ^notification.user_id) |> Repo.all()

    android_sessions =
      from(s in ApiDeviceSession,
        where: s.user_id == ^notification.user_id and not is_nil(s.push_token)
      )
      |> Repo.all()

    Repo.insert_all(
      Delivery,
      Enum.map(subscriptions, fn subscription ->
        %{
          notification_id: notification.id,
          push_subscription_id: subscription.id,
          channel: "web",
          attempts: 0,
          next_attempt_at: now,
          inserted_at: now,
          updated_at: now
        }
      end) ++
        Enum.map(android_sessions, fn session ->
          %{
            notification_id: notification.id,
            api_device_session_id: session.id,
            channel: "android",
            attempts: 0,
            next_attempt_at: now,
            inserted_at: now,
            updated_at: now
          }
        end),
      on_conflict: :nothing
    )

    :ok
  end

  # Keeps the public helper useful for direct callers and isolated tests. Real
  # persisted notifications use the durable delivery rows above.
  def notify(notification) do
    subscriptions =
      from(s in Subscription, where: s.user_id == ^notification.user_id) |> Repo.all()

    Enum.each(subscriptions, fn subscription ->
      case WebPush.send_push(subscription, legacy_payload(notification)) do
        {:ok, _status} -> :ok
        {:error, {:http, status}} when status in [404, 410] -> Repo.delete(subscription)
        {:error, reason} -> Logger.warning("push: delivery failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc "Fire-and-forget `notify/1`; disabled via config in tests."
  def notify_async(notification) do
    if Application.get_env(:veejr, :push_enabled, true) do
      Task.Supervisor.start_child(Veejr.TaskSupervisor, fn ->
        :ok = notify(notification)
        deliver_due()
      end)
    end

    :ok
  end

  @doc """
  Sends a content-free, non-message alert to all of a user's registered
  devices. Scheduled-call reminders use this path because they do not create
  encrypted-message notification rows.
  """
  def notify_user(%User{id: user_id}, payload) when is_map(payload) do
    subscriptions =
      from(s in Subscription, where: s.user_id == ^user_id)
      |> Repo.all()

    android_sessions =
      from(s in ApiDeviceSession,
        where: s.user_id == ^user_id and not is_nil(s.push_token)
      )
      |> Repo.all()

    Enum.each(subscriptions, fn subscription ->
      case WebPush.send_push(subscription, payload) do
        {:ok, _status} -> :ok
        {:error, {:http, status}} when status in [404, 410] -> Repo.delete(subscription)
        {:error, reason} -> Logger.warning("push: direct delivery failed: #{inspect(reason)}")
      end
    end)

    if AndroidPush.enabled?() do
      Enum.each(android_sessions, fn session ->
        case AndroidPush.send_push(session.push_token, payload) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("push: direct Android delivery failed: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc "Fire-and-forget `notify_user/2`; disabled with the normal push test setting."
  def notify_user_async(%User{} = user, payload) when is_map(payload) do
    if Application.get_env(:veejr, :push_enabled, true) do
      Task.Supervisor.start_child(Veejr.TaskSupervisor, fn -> notify_user(user, payload) end)
    end

    :ok
  end

  def deliver_due do
    now = DateTime.utc_now(:second)

    from(delivery in Delivery,
      where: delivery.next_attempt_at <= ^now,
      order_by: delivery.next_attempt_at,
      limit: 50,
      preload: [
        notification: [envelope: [:sender]],
        push_subscription: [],
        api_device_session: []
      ]
    )
    |> Repo.all()
    |> Enum.each(&deliver/1)
  end

  defp deliver(%Delivery{channel: "web", push_subscription: nil} = delivery),
    do: Repo.delete(delivery)

  defp deliver(%Delivery{channel: "android", api_device_session: nil} = delivery),
    do: Repo.delete(delivery)

  defp deliver(%Delivery{} = delivery) do
    payload = payload(delivery.notification)

    result =
      case delivery.channel do
        "web" ->
          WebPush.send_push(delivery.push_subscription, payload)

        "android" ->
          AndroidPush.send_push(
            delivery.api_device_session.push_token,
            android_payload(delivery.notification)
          )
      end

    case result do
      {:ok, _status} -> Repo.delete(delivery)
      :ok -> Repo.delete(delivery)
      {:error, {:http, status}} when status in [404, 410] -> expire_destination(delivery)
      {:error, reason} -> retry(delivery, reason)
    end
  end

  defp payload(notification) do
    action =
      if notification.state == "accepted",
        do: "Open veejr to read it.",
        else: "Open veejr to request it."

    %{
      title: "veejr",
      body:
        "#{Address.handle(notification.envelope.sender)} sent you an encrypted #{notification.envelope.kind}. #{action}",
      url: "/messages"
    }
  end

  defp legacy_payload(notification) do
    envelope = notification.envelope

    %{
      title: "veejr",
      body: "#{Address.handle(envelope.sender)} sent you an encrypted #{envelope.kind}.",
      url: "/messages"
    }
  end

  defp android_payload(notification),
    do: %{
      type: "new_message",
      count: 1,
      sender: Address.handle(notification.envelope.sender),
      kind: notification.envelope.kind
    }

  defp expire_destination(%Delivery{channel: "web", push_subscription: subscription} = delivery) do
    Repo.delete(subscription)
    Repo.delete(delivery)
  end

  defp expire_destination(%Delivery{channel: "android", api_device_session: session} = delivery) do
    Repo.update(Ecto.Changeset.change(session, push_token: nil, push_token_updated_at: nil))
    Repo.delete(delivery)
  end

  defp retry(delivery, reason) do
    attempts = delivery.attempts + 1
    seconds = min(trunc(:math.pow(2, attempts)) * 30, 6 * 60 * 60)

    Repo.update(
      Ecto.Changeset.change(delivery,
        attempts: attempts,
        next_attempt_at: DateTime.add(DateTime.utc_now(:second), seconds, :second),
        last_error: inspect(reason)
      )
    )

    Logger.warning("push: delivery retry scheduled: #{inspect(reason)}")
  end
end
