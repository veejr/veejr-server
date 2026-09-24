defmodule Veejr.Push.AndroidPush do
  @moduledoc false

  @scope "https://www.googleapis.com/auth/firebase.messaging"

  def enabled? do
    is_map(Application.get_env(:veejr, :fcm_service_account))
  end

  def send_push(token, payload) when is_binary(token) and is_map(payload) do
    with {:ok, account} <- service_account(), {:ok, access_token} <- access_token(account) do
      case Req.post(
             "https://fcm.googleapis.com/v1/projects/#{account["project_id"]}/messages:send",
             json: %{
               message: %{token: token, data: stringify(payload), android: %{priority: "HIGH"}}
             },
             headers: [{"authorization", "Bearer #{access_token}"}]
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp service_account do
    case Application.get_env(:veejr, :fcm_service_account) do
      %{"project_id" => project_id, "client_email" => email, "private_key" => key} = account
      when is_binary(project_id) and is_binary(email) and is_binary(key) ->
        {:ok, account}

      _ ->
        {:error, :not_configured}
    end
  end

  defp access_token(account) do
    assertion = jwt_assertion(account, System.system_time(:second))

    case Req.post("https://oauth2.googleapis.com/token",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body:
             URI.encode_query(%{
               "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
               "assertion" => assertion
             })
         ) do
      {:ok, %{status: status, body: %{"access_token" => token}}} when status in 200..299 ->
        {:ok, token}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The signed service-account JWT exchanged for an FCM access token. Public
  # only so the signing can be tested without calling Google.
  def jwt_assertion(account, now) do
    [
      %{"alg" => "RS256", "typ" => "JWT"},
      %{
        "iss" => account["client_email"],
        "scope" => @scope,
        "aud" => "https://oauth2.googleapis.com/token",
        "iat" => now,
        "exp" => now + 3600
      }
    ]
    |> Enum.map(&Base.url_encode64(Jason.encode!(&1), padding: false))
    |> then(fn [header, claims] ->
      signing_input = header <> "." <> claims
      signature = :public_key.sign(signing_input, :sha256, private_key(account["private_key"]))
      signing_input <> "." <> Base.url_encode64(signature, padding: false)
    end)
  end

  # :public_key.pem_decode/1 takes the PEM as a binary; a charlist raises
  # FunctionClauseError, which silently killed every Android push.
  defp private_key(pem) when is_binary(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp stringify(payload),
    do: Map.new(payload, fn {key, value} -> {to_string(key), to_string(value)} end)
end
