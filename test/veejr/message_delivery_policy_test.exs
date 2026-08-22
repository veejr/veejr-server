defmodule Veejr.MessageDeliveryPolicyTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Messaging, Repo, Social}

  setup do
    alice = keyed_user("policy_alice")
    bob = keyed_user("policy_bob")
    {:ok, request} = Social.send_friend_request(alice, bob.username)
    {:ok, _friendship} = Social.accept_friend_request(bob, request.id)
    %{alice: alice, bob: bob}
  end

  test "conversation, contact, and restrictive group precedence", %{alice: alice, bob: bob} do
    assert Messaging.automatic_delivery?(bob, alice)

    {:ok, group} = Social.create_group(bob, %{name: "Trusted"})
    {:ok, _membership} = Social.add_group_member(bob, group.id, alice.id)
    {:ok, _policy} = put(bob, "group", group.id, "automatic")
    assert Messaging.automatic_delivery?(bob, alice)

    {:ok, cautious} = Social.create_group(bob, %{name: "Cautious"})
    {:ok, _membership} = Social.add_group_member(bob, cautious.id, alice.id)
    {:ok, _policy} = put(bob, "group", cautious.id, "ask")
    refute Messaging.automatic_delivery?(bob, alice)

    {:ok, _policy} = put(bob, "contact", alice.id, "automatic")
    assert Messaging.automatic_delivery?(bob, alice)

    {:ok, _policy} = put(bob, "conversation", alice.id, "ask")
    refute Messaging.automatic_delivery?(bob, alice)
  end

  test "an explicit ask policy overrides the automatic default", %{alice: alice, bob: bob} do
    {:ok, _policy} = put(bob, "contact", alice.id, "ask")

    refute Messaging.automatic_delivery?(bob, alice)
  end

  test "automatic policy accepts new ciphertext without a consent action", %{
    alice: alice,
    bob: bob
  } do
    {:ok, _policy} = put(bob, "contact", alice.id, "automatic")

    {:ok, _batch_id, _deliveries} =
      Messaging.send_batch(alice, "message", [
        %{"recipient_id" => bob.id, "ciphertext" => "bob-copy", "nonce" => "bob-nonce"},
        %{"recipient_id" => alice.id, "ciphertext" => "self-copy", "nonce" => "self-nonce"}
      ])

    assert Messaging.list_pending_notifications(bob) == []
    assert [received] = Messaging.list_history(bob, kind: "message")
    assert received.ciphertext == "bob-copy"
  end

  test "a pending remote key change disables automatic delivery", %{alice: alice, bob: bob} do
    {:ok, _policy} = put(bob, "contact", alice.id, "automatic")
    alice |> Ecto.Changeset.change(pending_public_key: "unconfirmed") |> Repo.update!()

    refute Messaging.automatic_delivery?(bob, Repo.reload!(alice))
  end

  test "policies are ownership scoped", %{alice: alice, bob: bob} do
    stranger = keyed_user("policy_eve")

    assert {:error, :not_found} =
             Messaging.put_delivery_policy(bob, "contact", stranger.id, %{
               "acceptance" => "automatic",
               "notification" => "normal"
             })

    assert {:error, :not_found} =
             Messaging.put_delivery_policy(alice, "group", 999_999, %{
               "acceptance" => "automatic",
               "notification" => "normal"
             })
  end

  defp put(user, subject_type, subject_id, acceptance) do
    Messaging.put_delivery_policy(user, subject_type, subject_id, %{
      "acceptance" => acceptance,
      "notification" => "normal"
    })
  end

  defp keyed_user(username) do
    user = user_fixture(%{username: username})

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(:binary.copy(<<1>>, 32)),
        enc_secret_key: Base.encode64(:binary.copy(<<2>>, 48)),
        key_salt: Base.encode64(:binary.copy(<<3>>, 16)),
        key_nonce: Base.encode64(:binary.copy(<<4>>, 24))
      })

    user
  end
end
