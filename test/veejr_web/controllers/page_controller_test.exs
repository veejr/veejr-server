defmodule VeejrWeb.PageControllerTest do
  use VeejrWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "veejr"

    assert html =~
             ~s(<link id="favicon" rel="icon" type="image/svg+xml" href="/images/favicon-veejr.svg" data-state="default">)
  end
end
