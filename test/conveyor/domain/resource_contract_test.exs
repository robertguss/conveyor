defmodule Conveyor.Domain.ResourceContractTest do
  use ExUnit.Case, async: false

  @resources Conveyor.Domain.Resources.resource_modules()
  @tables Conveyor.Domain.Resources.table_names()

  test "registers every active Phase 0/1 resource in the Ash domain" do
    registered = Ash.Domain.Info.resources(Conveyor.Domain) |> MapSet.new()

    assert MapSet.new(@resources) == registered
  end

  test "tracks the backing table for every active resource" do
    assert length(@resources) == 46
    assert length(@tables) == 46
    assert length(Enum.uniq(@tables)) == 46
  end

  test "emits structured migration and guard evidence logs" do
    assert %{
             schema_version: "conveyor.domain_resource_contract@1",
             category: "domain_resource_migration",
             resource_count: 46,
             table_count: 46,
             resources: resources,
             immutable_fields: immutable_fields
           } = Conveyor.Domain.Resources.migration_log()

    assert length(resources) == 46
    assert "external_id" in immutable_fields

    assert %{
             schema_version: "conveyor.domain_resource_contract@1",
             category: "domain_resource_guard",
             failure_category: "immutable_field_update_rejected",
             resource: "Conveyor.Domain.Project",
             field: "external_id"
           } =
             Conveyor.Domain.Resources.guard_violation_log(Conveyor.Domain.Project, :external_id)
  end

  test "each resource supports Ash create, read, and update actions" do
    for resource <- @resources do
      suffix = resource |> Module.split() |> List.last() |> Macro.underscore()

      attrs = %{
        external_id: "#{suffix}-001",
        name: "#{suffix} baseline",
        status: "active",
        payload: %{"resource" => suffix}
      }

      assert {:ok, record} = Ash.create(resource, attrs, action: :create)
      assert record.external_id == attrs.external_id
      assert record.name == attrs.name
      assert record.status == "active"

      assert {:ok, [_ | _]} = Ash.read(resource, action: :read)

      assert {:ok, updated} =
               Ash.update(record, %{name: "#{suffix} updated", status: "paused"}, action: :update)

      assert updated.name == "#{suffix} updated"
      assert updated.status == "paused"
      assert updated.external_id == attrs.external_id
    end
  end

  test "immutable external ids are guarded by the update action" do
    for resource <- @resources do
      suffix = resource |> Module.split() |> List.last() |> Macro.underscore()

      assert {:ok, record} =
               Ash.create(
                 resource,
                 %{external_id: "#{suffix}-immutable", name: "#{suffix} immutable"},
                 action: :create
               )

      assert {:error, error} =
               Ash.update(record, %{external_id: "#{suffix}-changed"}, action: :update)

      assert Exception.message(error) =~ "external_id"
    end
  end
end
