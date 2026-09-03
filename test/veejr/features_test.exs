defmodule Veejr.FeaturesTest do
  use Veejr.DataCase

  import Veejr.AccountsFixtures

  alias Veejr.{Admin, Features, InstanceSettings}

  test "a new instance draws every control" do
    settings = InstanceSettings.get()

    assert settings.features == %{}
    assert Features.enabled?(:simple_contact_call)
    assert Features.enabled?(:simple_contact_game)
    assert Features.enabled?(:simple_contact_location)
    assert Features.disabled_ids() == []

    assert Enum.all?(Features.all(), & &1.default),
           "the shipped defaults are what a fresh instance draws, so they are all on"
  end

  test "an id nobody declared is off rather than an error" do
    refute Features.enabled?(:no_such_control)
  end

  test "an administrator turns one off and the rest stay on" do
    admin = user_fixture()

    assert {:ok, settings} =
             Admin.update_features(admin, %{
               "simple_contact_call" => "true",
               "simple_contact_game" => "false",
               "simple_contact_location" => "true"
             })

    assert Features.enabled?(:simple_contact_call, settings)
    refute Features.enabled?(:simple_contact_game, settings)
    assert Features.enabled?(:simple_contact_location, settings)

    assert Features.disabled_ids(settings) == [:simple_contact_game]

    assert %{simple_contact_call: true, simple_contact_game: false, simple_contact_location: true} =
             Features.enabled_map(settings)
  end

  test "only an administrator may change them" do
    _admin = user_fixture()
    member = user_fixture()

    assert {:error, :unauthorized} =
             Admin.update_features(member, %{"simple_contact_call" => "false"})

    assert Features.enabled?(:simple_contact_call)
  end

  test "the change is written to the audit log as what ended up off" do
    admin = user_fixture()

    {:ok, _settings} = Admin.update_features(admin, %{"simple_contact_location" => "false"})

    assert %{action: "instance.features_updated", details: details} =
             Admin.list_audit_events() |> hd()

    assert details["off"] == ["simple_contact_location"]
  end

  # The catalogue is the schema for a column the database does not type-check,
  # so nothing outside it may be stored.
  test "an id outside the catalogue is dropped rather than stored" do
    admin = user_fixture()

    {:ok, settings} =
      Admin.update_features(admin, %{
        "simple_contact_call" => "false",
        "definitely_not_a_feature" => "true"
      })

    refute Map.has_key?(settings.features, "definitely_not_a_feature")

    assert Map.keys(settings.features) ==
             Enum.map(Features.all(), &to_string(&1.id)) |> Enum.sort()
  end

  # A dropped checkbox should not read as "switch this off".
  test "a feature missing from the form keeps its default" do
    assert Features.normalize(%{"simple_contact_call" => "false"}) == %{
             "simple_contact_call" => false,
             "simple_contact_game" => true,
             "simple_contact_location" => true
           }
  end

  test "a feature added after an instance last saved takes its default" do
    admin = user_fixture()
    {:ok, _settings} = Admin.update_features(admin, %{"simple_contact_call" => "false"})

    # Stand in for the release that adds a control this row has never seen.
    settings = %{InstanceSettings.get() | features: %{"simple_contact_call" => false}}

    refute Features.enabled?(:simple_contact_call, settings)
    assert Features.enabled?(:simple_contact_game, settings)
  end

  test "a row written before the column existed reads as all defaults" do
    assert Features.enabled_map(%{features: nil}) ==
             Map.new(Features.all(), &{&1.id, &1.default})
  end

  test "the catalogue groups every feature under a group it declares" do
    group_ids = Enum.map(Features.groups(), & &1.id)

    for feature <- Features.all() do
      assert feature.group in group_ids, "#{feature.id} is filed under an undeclared group"
      assert feature.name != ""
      assert feature.summary != ""
    end

    assert Enum.flat_map(Features.catalogue(), & &1.features) |> length() ==
             length(Features.all())
  end
end
