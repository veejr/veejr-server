defmodule Veejr.PushDeliveryTest do
  use Veejr.DataCase, async: false

  import Ecto.Query
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Push, Repo, Social}
  alias Veejr.Push.Delivery

  setup do
    alice = user_fixture()
    bob = user_fixture()
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _} = Social.accept_friend_request(bob, request.id)

    {:ok, session, _tokens} =
      Accounts.create_api_device_session(bob, %{"name" => "Bob's phone", "platform" => "android"})

    :ok = Push.register_android_token(bob, session.id, "bob-fcm-token")

    for text <- ["first", "second"] do
      {:ok, _batch, _deliveries} =
        Messaging.send_batch(alice, "message", [
          %{"recipient_id" => bob.id, "ciphertext" => text, "nonce" => "n"}
        ])
    end

    # Start from an empty queue; the test inserts the deliveries it needs.
    Repo.delete_all(Delivery)

    notifications =
      Repo.all(
        from n in Veejr.Messaging.Notification, where: n.user_id == ^bob.id, order_by: n.id
      )

    %{notifications: notifications, session: session}
  end

  test "a day-old undelivered alert is dropped instead of sent", %{
    notifications: [older, newer],
    session: session
  } do
    stale = insert_delivery(older, session, DateTime.add(DateTime.utc_now(:second), -2, :day))
    fresh = insert_delivery(newer, session, DateTime.utc_now(:second))

    Push.deliver_due()

    refute Repo.get(Delivery, stale.id)
    # FCM is not configured in tests, so the fresh alert is attempted and
    # rescheduled rather than dropped.
    assert %Delivery{attempts: 1} = Repo.get(Delivery, fresh.id)
  end

  defp insert_delivery(notification, session, inserted_at) do
    Repo.insert!(%Delivery{
      notification_id: notification.id,
      api_device_session_id: session.id,
      channel: "android",
      attempts: 0,
      next_attempt_at: DateTime.utc_now(:second),
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end
end
