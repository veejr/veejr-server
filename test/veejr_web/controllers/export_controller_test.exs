defmodule VeejrWeb.ExportControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  test "downloads a private account backup for the signed-in user", %{conn: conn} do
    user = user_fixture(%{username: "backup_download"})

    conn =
      conn
      |> log_in_user(user)
      |> get(~p"/export")

    assert response(conn, :ok)
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "veejr-backup_download-export.zip"
  end

  test "requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/export")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
