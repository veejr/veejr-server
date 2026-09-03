defmodule VeejrWeb.MapLiveTest do
  use VeejrWeb.ConnCase

  import Phoenix.LiveViewTest
  import Veejr.AccountsFixtures

  alias Veejr.{Accounts, Social}

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, user} =
      Accounts.setup_user_keys(user, %{
        "public_key" => Base.encode64(String.pad_trailing("public-key", 32, "x")),
        "enc_secret_key" => Base.encode64(String.pad_trailing("wrapped-key", 48, "x")),
        "key_salt" => Base.encode64(String.pad_trailing("salt", 16, "x")),
        "key_nonce" => Base.encode64(String.pad_trailing("nonce", 24, "x"))
      })

    %{conn: log_in_user(conn, user), user: user}
  end

  test "pushes a newly shared location into the open map", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/map")

    html =
      render_hook(view, "send_batch", %{
        "kind" => "location",
        "envelopes" => [
          %{"recipient_id" => user.id, "ciphertext" => "ciphertext", "nonce" => "nonce"}
        ]
      })

    assert html =~ "Shared on the map."

    assert_push_event view, "map:item_added", %{
      kind: "location",
      label: "You",
      ciphertext: "ciphertext",
      nonce: "nonce",
      public_id: _,
      peer_key: _,
      time: _,
      delete_label: "Delete everywhere",
      delete_confirm: _
    }
  end

  test "a note started from someone's photo arrives with them chosen", %{
    conn: conn,
    user: user
  } do
    friend = user_fixture()
    {:ok, request} = Social.send_friend_request(user, friend.username)
    {:ok, _friendship} = Social.accept_friend_request(friend, request.id)

    {:ok, view, _html} = live(conn, "/map?friend=#{friend.id}")

    assert has_element?(
             view,
             "#note-composer input[name='friends[]'][value='#{friend.id}'][checked]"
           )

    # An id that is not a friend of theirs chooses nobody rather than leaking
    # that the account exists.
    {:ok, view, _html} = live(conn, "/map?friend=#{friend.id + 999}")
    refute has_element?(view, "#note-composer input[name='friends[]'][checked]")
  end
end
