defmodule VeejrWeb.PageControllerTest do
  use VeejrWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "veejr"

    assert html =~
             ~s(<link id="favicon" rel="icon" type="image/svg+xml" href="/images/favicon-veejr.svg" data-state="default">)
  end

  test "the digested web manifest is served", %{conn: conn} do
    static_dir = :veejr |> :code.priv_dir() |> Path.join("static")
    [manifest] = Path.wildcard(Path.join(static_dir, "manifest-*.webmanifest"))

    conn = get(conn, "/#{Path.basename(manifest)}")

    assert response(conn, 200) =~ "\"name\": \"veejr\""
  end
end
