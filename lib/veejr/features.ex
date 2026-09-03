defmodule Veejr.Features do
  @moduledoc """
  The interface controls an administrator can switch off.

  A feature here is one *visible control* — a button, a panel, an entry point.
  Turning one off removes it from the page that draws it; it is not a
  permission. Every capability behind these switches is still reachable from
  the full pages (`/calls`, `/craps`, `/map`), so an instance that hides the
  location button on `/contacts/simple` has tidied a page, not revoked
  anything. Say that plainly rather than implying a boundary this does not
  enforce; `Veejr.AddOns` is the setting that actually closes a door.

  ## Why a catalogue rather than a column each

  `craps_enabled` is a column because there is one of it. Interface switches
  arrive in batches, and a column per switch means a migration, a schema
  field, a cast list and a form field for every one. So the catalogue lives
  here in code and the instance stores a single map of `id => boolean` in
  `instance_settings.features`.

  What that buys: a new feature ships by adding an entry below, and the admin
  screen grows a row for it with no template change. What it costs: the stored
  map is not validated by the database, so `normalize/1` is the only way in
  and it keeps nothing it does not recognise.

  ## Defaults

  Every feature declares its own `:default`, and an id absent from the stored
  map takes it. That is what makes a new feature safe to ship: instances that
  have never opened this screen get the default, and instances that have get
  the value they last saw for the features that existed then.

  ## Adding one

  Add a map to `@features` with an id, the group it belongs under, a name and
  summary an administrator will read, and a default. Then have the page that
  draws the control ask `enabled?/2` — or `enabled_map/1` if it draws several,
  which reads the settings row once.
  """

  alias Veejr.InstanceSettings

  @groups [
    %{
      id: :simple_contacts,
      name: "Simple contacts",
      summary: "The buttons around each photo on the plain Contacts page."
    }
  ]

  @features [
    %{
      id: :simple_contact_call,
      group: :simple_contacts,
      name: "Call",
      summary: "Ring a contact now, or pick a time, from their photo.",
      default: true
    },
    %{
      id: :simple_contact_game,
      group: :simple_contacts,
      name: "Games",
      summary:
        "Ask a contact to play. Drawn only when the instance also offers " <>
          "an add-on to play, so turning this off hides it either way.",
      default: true
    },
    %{
      id: :simple_contact_location,
      group: :simple_contacts,
      name: "Location notes",
      summary: "Send a contact an encrypted note about where you are.",
      default: true
    }
  ]

  @doc "Every feature in the release, on or off."
  def all, do: @features

  @doc "The groups features are shown under, in catalogue order."
  def groups, do: @groups

  @doc "The catalogue entry for an id, or nil."
  def get(id) when is_atom(id), do: Enum.find(@features, &(&1.id == id))

  @doc """
  Groups with their features attached, for a screen that renders the lot.

  A group with no features is dropped rather than drawn empty.
  """
  def catalogue do
    @groups
    |> Enum.map(&Map.put(&1, :features, Enum.filter(@features, fn f -> f.group == &1.id end)))
    |> Enum.reject(&(&1.features == []))
  end

  @doc "Whether this instance draws the given control. An unknown id is off."
  def enabled?(id, settings \\ InstanceSettings.get()) when is_atom(id) do
    case get(id) do
      nil -> false
      feature -> effective(feature, stored(settings))
    end
  end

  @doc """
  Every feature's effective state, keyed by id.

  A page drawing several controls wants this rather than repeated
  `enabled?/2` calls, each of which would re-read the settings row.
  """
  def enabled_map(settings \\ InstanceSettings.get()) do
    stored = stored(settings)

    Map.new(@features, &{&1.id, effective(&1, stored)})
  end

  @doc "The ids this instance has switched off, for the audit log."
  def disabled_ids(settings \\ InstanceSettings.get()) do
    settings
    |> enabled_map()
    |> Enum.reject(fn {_id, on?} -> on? end)
    |> Enum.map(fn {id, _off} -> id end)
  end

  @doc "Starting values for the admin form: every feature's effective state."
  def form_params(settings \\ InstanceSettings.get()) do
    Map.new(enabled_map(settings), fn {id, on?} -> {to_string(id), on?} end)
  end

  @doc """
  Turns a submitted form into the map to store.

  Only ids in the catalogue survive, so a crafted post cannot write junk into
  a column the database does not type-check. The whole form is submitted every
  time, but an id that is somehow missing falls back to its default rather
  than to `false` — a dropped checkbox should not silently switch a control
  off.
  """
  def normalize(params) when is_map(params) do
    Map.new(@features, fn feature ->
      {to_string(feature.id), truthy(Map.get(params, to_string(feature.id)), feature.default)}
    end)
  end

  defp effective(feature, stored), do: Map.get(stored, to_string(feature.id), feature.default)

  # The column is nullable, so a row written before this shipped loads as nil.
  defp stored(%{features: features}) when is_map(features), do: features
  defp stored(_settings), do: %{}

  defp truthy(value, _default) when value in [true, "true", "on", "1"], do: true
  defp truthy(value, _default) when value in [false, "false", "off", "0"], do: false
  defp truthy(_value, default), do: default
end
