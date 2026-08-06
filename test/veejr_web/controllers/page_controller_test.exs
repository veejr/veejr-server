defmodule VeejrWeb.PageControllerTest do
  use VeejrWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "veejr"

    assert html =~
             ~s(<link id="favicon" rel="icon" type="image/svg+xml" href="/images/favicon-veejr.svg" data-state="default">)
  end

  # The endpoint's `only:` lists the undigested `manifest.webmanifest`, so
  # serving the digested `manifest-<hash>.webmanifest` from the root depends
  # entirely on `only_matching: ["manifest-"]`. Plug.Static reads the file off
  # disk, so this writes one of that shape rather than globbing for a real
  # digest: the test job never runs `mix assets.deploy`, so a glob matched only
  # on machines carrying a leftover local build and raised MatchError in CI.
  test "the endpoint serves a root-level digested web manifest", %{conn: conn} do
    name = "manifest-0123456789abcdef0123456789abcdef.webmanifest"
    path = :veejr |> :code.priv_dir() |> Path.join("static") |> Path.join(name)

    File.write!(path, ~s({\n  "name": "veejr"\n}))
    on_exit(fn -> File.rm(path) end)

    conn = get(conn, "/#{name}")

    assert response(conn, 200) =~ ~s("name": "veejr")
  end
end
