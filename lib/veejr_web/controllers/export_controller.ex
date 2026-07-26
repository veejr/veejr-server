defmodule VeejrWeb.ExportController do
  use VeejrWeb, :controller

  def download(conn, _params) do
    user = conn.assigns.current_scope.user
    {:ok, filename, zip_binary} = Veejr.Export.build(user)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_download({:binary, zip_binary},
      filename: filename,
      content_type: "application/zip"
    )
  end
end
