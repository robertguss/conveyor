defmodule Conveyor.Domain.ResourceContractTest do
  use ExUnit.Case, async: false

  @resources Conveyor.Domain.Resources.resource_modules()
  @tables Conveyor.Domain.Resources.table_names()
  @append_only_resources Conveyor.Domain.Resources.append_only_resources()
  @mutable_resources @resources -- @append_only_resources

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

  test "mutable resources support Ash create, read, and update actions" do
    for resource <- @mutable_resources do
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
    for resource <- @mutable_resources do
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

  test "append-only resources do not expose update or destroy actions" do
    for resource <- @append_only_resources do
      assert Ash.Resource.Info.action(resource, :create)
      assert Ash.Resource.Info.action(resource, :read)
      refute Ash.Resource.Info.action(resource, :update)
      refute Ash.Resource.Info.action(resource, :destroy)
    end
  end

  test "RunSpec generation is stable and binds station IO to the content address" do
    run_spec = Conveyor.Domain.RunSpec.build!(run_spec_attrs())

    reordered =
      Conveyor.Domain.RunSpec.build!(run_spec_attrs(%{contract_digests: reordered_digest_set()}))

    assert run_spec["run_spec_sha256"] == reordered["run_spec_sha256"]
    assert run_spec["run_spec_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/

    for station <- run_spec["stations"] do
      assert station["inputs"]["run_spec_sha256"] == run_spec["run_spec_sha256"]
      assert station["outputs"]["run_spec_sha256"] == run_spec["run_spec_sha256"]
    end

    assert %{
             schema_version: "conveyor.run_spec_digest_summary@1",
             category: "run_spec_digest_set",
             run_id: "run-phase1-demo",
             run_spec_sha256: run_spec_sha256,
             digest_count: 22,
             station_keys: ["readiness", "evidence"]
           } = Conveyor.Domain.RunSpec.digest_summary(run_spec)

    assert run_spec_sha256 == run_spec["run_spec_sha256"]
  end

  test "contract changes require a new RunSpec and RunAttempt instead of mutating evidence" do
    old_run_spec = Conveyor.Domain.RunSpec.build!(run_spec_attrs())

    new_attrs =
      run_spec_attrs(%{
        contract_digests: Map.put(digest_set(), "policy", "sha256:policy-v2")
      })

    new_run_spec = Conveyor.Domain.RunSpec.build!(new_attrs)

    refute Conveyor.Domain.RunSpec.equivalent?(old_run_spec, new_run_spec)

    assert %{
             schema_version: "conveyor.run_spec_diff@1",
             category: "run_spec_contract_change",
             finding_code: "contract_change_requires_new_run_spec_and_run_attempt",
             action: "create_new_run_spec_and_run_attempt",
             old_run_spec_sha256: old_sha256,
             new_run_spec_sha256: new_sha256,
             changed_digest_keys: ["policy"]
           } = Conveyor.Domain.RunSpec.diff_finding(old_run_spec, new_run_spec)

    assert old_sha256 == old_run_spec["run_spec_sha256"]
    assert new_sha256 == new_run_spec["run_spec_sha256"]
  end

  test "RunSpec payloads are created once and not updated in place" do
    attrs = Conveyor.Domain.RunSpec.create_attrs!(run_spec_attrs())

    assert {:ok, record} = Ash.create(Conveyor.Domain.RunSpec, attrs, action: :create)

    assert record.external_id == record.payload["run_spec_sha256"]

    assert {:error, error} =
             Ash.update(
               record,
               %{payload: Map.put(record.payload, "run_id", "mutated")},
               action: :update
             )

    assert Exception.message(error) =~ "payload"
  end

  defp run_spec_attrs(overrides \\ %{}) do
    %{
      run_id: "run-phase1-demo",
      project_id: "project-conveyor",
      base_commit: "abc1234",
      slice_id: "slice-demo",
      autonomy_level: "L1",
      contract_digests: digest_set(),
      stations: [
        %{
          station_key: "readiness",
          intent: "Verify the run can start from locked inputs.",
          inputs: %{project_config: "locked"},
          outputs: %{report: "readiness.json"}
        },
        %{
          station_key: "evidence",
          intent: "Collect evidence without mutating the locked contract.",
          inputs: %{artifact_plan: "required"},
          outputs: %{bundle_manifest: "run_bundle.json"}
        }
      ]
    }
    |> Map.merge(overrides)
  end

  defp digest_set do
    Map.new(Conveyor.Domain.RunSpec.digest_keys(), fn key -> {key, "sha256:#{key}-v1"} end)
  end

  defp reordered_digest_set do
    digest_set()
    |> Enum.reverse()
    |> Map.new()
  end
end
