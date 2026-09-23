defmodule VeejrWeb.ChannelCase do
  @moduledoc """
  Test case for channels, with the SQL sandbox enabled.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import VeejrWeb.ChannelCase

      @endpoint VeejrWeb.Endpoint
    end
  end

  setup tags do
    Veejr.DataCase.setup_sandbox(tags)
    :ok
  end
end
