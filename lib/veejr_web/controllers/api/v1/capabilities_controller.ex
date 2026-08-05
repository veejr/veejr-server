defmodule VeejrWeb.Api.V1.CapabilitiesController do
  use VeejrWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      api_versions: [1],
      payload_versions: [1],
      max_blob_bytes: Veejr.Messaging.max_blob_size(),
      message_kinds: Veejr.Messaging.Envelope.kinds(),
      instance_mode: Veejr.instance_mode(),
      android_push: Veejr.Push.AndroidPush.enabled?(),
      add_ons: Enum.map(Veejr.AddOns.enabled_ids(), &to_string/1)
    })
  end
end
