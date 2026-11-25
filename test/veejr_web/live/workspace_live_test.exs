defmodule VeejrWeb.WorkspaceLiveTest do
  use VeejrWeb.ConnCase
  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures
  alias Veejr.{Accounts, Messaging}

  test "requires login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, "/workspace")
  end

  test "pages only the caller's authorized history and resolves only friends", %{conn: conn} do
    user = keyed_user()
    other = keyed_user()

    {:ok, _, _} =
      Messaging.send_batch(user, "self_note", [
        %{"recipient_id" => user.id, "ciphertext" => "mine", "nonce" => "nonce"}
      ])

    {:ok, _, _} =
      Messaging.send_batch(other, "self_note", [
        %{"recipient_id" => other.id, "ciphertext" => "theirs", "nonce" => "nonce"}
      ])

    {:ok, view, _} = live(log_in_user(conn, user), "/workspace")
    assert has_element?(view, "#private-workspace[phx-hook=PrivateWorkspace]")
    assert has_element?(view, "#workspace-search-tab")
    _ = render_hook(view, "workspace_page", %{})
    socket = %Phoenix.LiveView.Socket{assigns: %{current_scope: Accounts.Scope.for_user(user)}}

    assert {:reply, %{items: [%{ciphertext: "mine"}]}, _} =
             VeejrWeb.WorkspaceLive.handle_event("workspace_page", %{}, socket)

    assert {:reply, %{recipients: [%{id: id}]}, _} =
             VeejrWeb.WorkspaceLive.handle_event("workspace_recipients", %{}, socket)

    assert id == to_string(user.id)
  end

  defp keyed_user do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        enc_secret_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        key_salt: Base.encode64(:crypto.strong_rand_bytes(16)),
        key_nonce: Base.encode64(:crypto.strong_rand_bytes(24))
      })

    user
  end
end
