defmodule Veejr.Push.AndroidPushTest do
  use ExUnit.Case, async: true

  alias Veejr.Push.AndroidPush

  # A Google service-account JSON carries a PKCS#8 "BEGIN PRIVATE KEY" PEM.
  setup do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, private_key)])

    public_key =
      {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    account = %{
      "project_id" => "veejr-test",
      "client_email" => "push@veejr-test.iam.gserviceaccount.com",
      "private_key" => pem
    }

    %{account: account, public_key: public_key}
  end

  test "signs the service-account assertion with the account key", %{
    account: account,
    public_key: public_key
  } do
    assertion = AndroidPush.jwt_assertion(account, 1_700_000_000)
    [header, claims, signature] = String.split(assertion, ".")

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             public_key
           )

    claims = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["iss"] == account["client_email"]
    assert claims["aud"] == "https://oauth2.googleapis.com/token"
    assert claims["exp"] - claims["iat"] == 3600
  end
end
