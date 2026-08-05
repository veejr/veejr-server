defmodule Veejr.AddOns do
  @moduledoc """
  The catalogue of optional shared programs an instance can offer.

  An add-on is a self-contained activity with its own page, its own state, and
  its own invited roster. While one is off it is not linked, not routed, and
  none of its assets are downloaded — a viewer of an instance that does not
  offer craps cannot tell the code is in the release.

  ## Trust posture

  Every entry declares a `:trust`, and that declaration is written for players
  rather than for this module. Veejr's own promise is that the server stores
  ciphertext it cannot read. An add-on marked `:refereed` sets that promise
  aside on purpose: the server decides outcomes, keeps state hidden from the
  people playing, and is trusted by all of them to do it honestly. Craps
  cannot work any other way — someone has to roll the dice and hold the chips.
  A player is entitled to know which kind of room they have walked into, so
  the posture is surfaced in the admin panel and at the table itself.

  ## Where configuration lives

  The catalogue is code because the set of add-ons ships with the release.
  Whether a given instance offers one, and how it is tuned, lives in
  `Veejr.InstanceSettings` so an administrator can change it from `/admin`
  without a deploy and with the change recorded in the audit log.

  ## Adding one

  There is deliberately no behaviour, registry, or dynamic route mounting
  here: a plugin system designed against a single plugin is designed against
  guesses. What a second add-on has to settle is written down instead, and
  the machinery can grow once something has exercised it twice.

  A new add-on decides, and states somewhere a reader will find it:

    * its **trust posture** — `:sealed` if the server only relays what it
      cannot read, `:refereed` if the server is a trusted participant;
    * **who may be invited** — local members, emailed guest capabilities in
      the manner of `Veejr.GuestConferences`, or federated `user@authority`
      friends, which is materially harder and nothing supports yet;
    * what it needs in the **supervision tree**, if anything, following
      `Veejr.WatchParties`;
    * its **route**, added to the `:app` live session in the router;
    * its **asset story** — anything heavy is vendored into `assets/vendor/`
      and pulled in with a dynamic `import()` so a browser downloads it only
      on the page that needs it, as the document editors do.
  """

  alias Veejr.InstanceSettings

  @add_ons [
    %{
      id: :craps,
      name: "Craps",
      summary: "A shared table with 3D dice, play-money chips, and invited friends.",
      trust: :refereed,
      trust_note:
        "The server rolls the dice, holds the chips, and settles every bet. " <>
          "Nothing at the table is end-to-end encrypted the way messages are.",
      setting: :craps_enabled,
      path: "/craps",
      icon: "hero-cube"
    }
  ]

  @dice_modes ["fair", "house"]

  @doc "Every add-on in the release, offered or not."
  def all, do: @add_ons

  @doc "The catalogue entry for an id, or nil."
  def get(id) when is_atom(id), do: Enum.find(@add_ons, &(&1.id == id))

  @doc "Whether this instance offers the given add-on."
  def enabled?(id, settings \\ InstanceSettings.get()) do
    case get(id) do
      nil -> false
      add_on -> Map.fetch!(settings, add_on.setting) == true
    end
  end

  @doc "The catalogue entries this instance offers, in catalogue order."
  def enabled(settings \\ InstanceSettings.get()) do
    Enum.filter(@add_ons, &(Map.fetch!(settings, &1.setting) == true))
  end

  @doc "The ids this instance offers, for the capabilities endpoint."
  def enabled_ids(settings \\ InstanceSettings.get()) do
    settings |> enabled() |> Enum.map(& &1.id)
  end

  @doc """
  How the craps table draws dice.

    * `"fair"` — every combination equally likely, 1/36 each. The default.
    * `"house"` — weighted toward 7, which gives the house an edge.

  Fair is the default because the administrator choosing this is usually also
  sitting at the table, and dice weighted in secret by one of the players is
  not a house edge, it is cheating. The mode in force is shown at the table
  either way, so `"house"` is a disclosed choice rather than a hidden one.
  """
  def craps_dice_mode(settings \\ InstanceSettings.get()), do: settings.craps_dice_mode

  @doc "The dice modes the craps table accepts."
  def dice_modes, do: @dice_modes
end
