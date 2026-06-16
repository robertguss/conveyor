defmodule Conveyor.Domain.ActiveResource do
  @moduledoc """
  Shared Ash/Postgres contract for Phase 0/1 active control-plane resources.

  The first domain slice keeps resources intentionally uniform. Later beads can
  specialize lifecycle actions and relationships without changing the immutable
  identity contract established here.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    update_accept = Keyword.get(opts, :update_accept, [:name, :status, :payload])

    quote do
      use Ash.Resource,
        otp_app: :conveyor,
        domain: Conveyor.Domain,
        data_layer: AshPostgres.DataLayer

      postgres do
        table(unquote(table))
        repo(Conveyor.Repo)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:external_id, :name, :status, :payload])
        end

        update :update do
          primary?(true)
          accept(unquote(update_accept))
        end
      end

      attributes do
        uuid_primary_key(:id)

        attribute :external_id, :string do
          allow_nil?(false)
          public?(true)
          constraints(min_length: 1)
        end

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
          constraints(min_length: 1)
        end

        attribute :status, :string do
          allow_nil?(false)
          public?(true)
          default("active")
          constraints(match: ~r/^(active|paused|archived)$/)
        end

        attribute :payload, :map do
          allow_nil?(false)
          public?(true)
          default(%{})
        end

        create_timestamp :inserted_at do
          public?(true)
        end

        update_timestamp :updated_at do
          public?(true)
        end
      end

      identities do
        identity(:unique_external_id, [:external_id])
      end
    end
  end
end

defmodule Conveyor.Domain.Resources do
  @moduledoc """
  Inventory of active Phase 0/1 Ash resources and their backing tables.
  """

  @schema_version "conveyor.domain_resource_contract@1"
  @immutable_fields [:id, :external_id, :inserted_at]
  @append_only_resources [Conveyor.Domain.LedgerEvent]
  @resource_specs [
    {Conveyor.Domain.Project, :projects},
    {Conveyor.Domain.ToolchainProfile, :toolchain_profiles},
    {Conveyor.Domain.CacheMount, :cache_mounts},
    {Conveyor.Domain.Plan, :plans},
    {Conveyor.Domain.Requirement, :requirements},
    {Conveyor.Domain.HumanDecision, :human_decisions},
    {Conveyor.Domain.HumanApproval, :human_approvals},
    {Conveyor.Domain.ExternalChange, :external_changes},
    {Conveyor.Domain.PatchEquivalence, :patch_equivalences},
    {Conveyor.Domain.PlanAudit, :plan_audits},
    {Conveyor.Domain.Epic, :epics},
    {Conveyor.Domain.Slice, :slices},
    {Conveyor.Domain.DiffPolicy, :diff_policies},
    {Conveyor.Domain.ReviewPolicy, :review_policies},
    {Conveyor.Domain.AgentBrief, :agent_briefs},
    {Conveyor.Domain.ContractLock, :contract_locks},
    {Conveyor.Domain.TestPack, :test_packs},
    {Conveyor.Domain.VerificationSuite, :verification_suites},
    {Conveyor.Domain.TestPackCalibration, :test_pack_calibrations},
    {Conveyor.Domain.ContextPack, :context_packs},
    {Conveyor.Domain.InstructionSource, :instruction_sources},
    {Conveyor.Domain.CodeQualityRun, :code_quality_runs},
    {Conveyor.Domain.RunPrompt, :run_prompts},
    {Conveyor.Domain.RunSpec, :run_specs},
    {Conveyor.Domain.WorkspaceMaterialization, :workspace_materializations},
    {Conveyor.Domain.AgentProfile, :agent_profiles},
    {Conveyor.Domain.RunAttempt, :run_attempts},
    {Conveyor.Domain.AgentSession, :agent_sessions},
    {Conveyor.Domain.PatchSet, :patch_sets},
    {Conveyor.Domain.RiskAssessment, :risk_assessments},
    {Conveyor.Domain.StationRun, :station_runs},
    {Conveyor.Domain.Evidence, :evidence},
    {Conveyor.Domain.ToolInvocation, :tool_invocations},
    {Conveyor.Domain.Review, :reviews},
    {Conveyor.Domain.GateResult, :gate_results},
    {Conveyor.Domain.Artifact, :artifacts},
    {Conveyor.Domain.RunBundle, :run_bundles},
    {Conveyor.Domain.ReviewerHealth, :reviewer_health},
    {Conveyor.Domain.GateHealth, :gate_health},
    {Conveyor.Domain.LedgerEvent, :ledger_events},
    {Conveyor.Domain.Policy, :policies},
    {Conveyor.Domain.RetentionPolicy, :retention_policies},
    {Conveyor.Domain.RunBudget, :run_budgets},
    {Conveyor.Domain.Incident, :incidents},
    {Conveyor.Domain.StationEffect, :station_effects},
    {Conveyor.Domain.CredentialLease, :credential_leases}
  ]

  def resource_specs, do: @resource_specs
  def resource_modules, do: Enum.map(@resource_specs, &elem(&1, 0))
  def table_names, do: Enum.map(@resource_specs, &elem(&1, 1))
  def immutable_fields, do: @immutable_fields
  def append_only_resources, do: @append_only_resources

  def migration_log do
    %{
      schema_version: @schema_version,
      category: "domain_resource_migration",
      resource_count: length(@resource_specs),
      table_count: length(table_names()),
      resources:
        Enum.map(@resource_specs, fn {resource, table_name} ->
          %{resource: inspect(resource), table: Atom.to_string(table_name)}
        end),
      immutable_fields: Enum.map(@immutable_fields, &Atom.to_string/1)
    }
  end

  def guard_violation_log(resource, field) do
    %{
      schema_version: @schema_version,
      category: "domain_resource_guard",
      failure_category: "immutable_field_update_rejected",
      resource: inspect(resource),
      field: Atom.to_string(field),
      immutable_fields: Enum.map(@immutable_fields, &Atom.to_string/1)
    }
  end
end

defmodule Conveyor.Domain.PayloadHelpers do
  @moduledoc false

  def fetch_required!(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) ||
      raise ArgumentError, "missing required payload field: #{key}"
  end

  def normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  def normalize_map(_map), do: raise(ArgumentError, "payload metadata must be a map")

  def sha256_binary(binary) when is_binary(binary) do
    "sha256:" <>
      (:crypto.hash(:sha256, binary)
       |> Base.encode16(case: :lower))
  end

  def canonical_sha256(payload) do
    sha256_binary(canonical_json(payload))
  end

  def iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def iso8601(value) when is_binary(value), do: value

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(key) <> ":" <> canonical_json(value)
    end)
    |> then(&"{#{&1}}")
  end

  defp canonical_json(list) when is_list(list) do
    list
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&"[#{&1}]")
  end

  defp canonical_json(value), do: Jason.encode!(value)
end

defmodule Conveyor.Domain.Project do
  use Conveyor.Domain.ActiveResource, table: "projects"
end

defmodule Conveyor.Domain.ToolchainProfile do
  use Conveyor.Domain.ActiveResource, table: "toolchain_profiles"
end

defmodule Conveyor.Domain.CacheMount do
  use Conveyor.Domain.ActiveResource, table: "cache_mounts"
end

defmodule Conveyor.Domain.Plan do
  use Conveyor.Domain.ActiveResource, table: "plans"
end

defmodule Conveyor.Domain.Requirement do
  use Conveyor.Domain.ActiveResource, table: "requirements"
end

defmodule Conveyor.Domain.HumanDecision do
  use Conveyor.Domain.ActiveResource, table: "human_decisions"
end

defmodule Conveyor.Domain.HumanApproval do
  use Conveyor.Domain.ActiveResource, table: "human_approvals"

  @schema_version "conveyor.human_approval@1"

  def record_external_action!(attrs) when is_map(attrs) do
    %{
      "schema_version" => @schema_version,
      "approval_id" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :approval_id),
      "actor" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :actor),
      "action" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :action),
      "target" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :target),
      "reason" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :reason),
      "occurred_at" =>
        attrs
        |> Conveyor.Domain.PayloadHelpers.fetch_required!(:occurred_at)
        |> Conveyor.Domain.PayloadHelpers.iso8601(),
      "manual_external_action" => true,
      "external_change" =>
        attrs
        |> Map.get(:external_change, Map.get(attrs, "external_change", %{}))
        |> Conveyor.Domain.PayloadHelpers.normalize_map(),
      "evidence_refs" => Map.get(attrs, :evidence_refs, Map.get(attrs, "evidence_refs", []))
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = record_external_action!(attrs)

    %{
      external_id: payload["approval_id"],
      name: payload["action"],
      status: "active",
      payload: payload
    }
  end
end

defmodule Conveyor.Domain.ExternalChange do
  use Conveyor.Domain.ActiveResource, table: "external_changes"

  @schema_version "conveyor.external_change@1"

  def record!(attrs) when is_map(attrs) do
    %{
      "schema_version" => @schema_version,
      "change_id" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :change_id),
      "system" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :system),
      "change_type" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :change_type),
      "actor" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :actor),
      "summary" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :summary),
      "occurred_at" =>
        attrs
        |> Conveyor.Domain.PayloadHelpers.fetch_required!(:occurred_at)
        |> Conveyor.Domain.PayloadHelpers.iso8601(),
      "metadata" =>
        attrs
        |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
        |> Conveyor.Domain.PayloadHelpers.normalize_map()
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = record!(attrs)

    %{
      external_id: payload["change_id"],
      name: payload["summary"],
      status: "active",
      payload: payload
    }
  end
end

defmodule Conveyor.Domain.PatchEquivalence do
  use Conveyor.Domain.ActiveResource, table: "patch_equivalences"

  @schema_version "conveyor.patch_equivalence@1"
  @classifications [
    "exact",
    "equivalent_with_human_edits",
    "divergent",
    "partial",
    "unknown"
  ]

  def classifications, do: @classifications

  def classify(attrs) when is_map(attrs) do
    expected = Map.get(attrs, :expected_patch_sha256, Map.get(attrs, "expected_patch_sha256"))
    applied = Map.get(attrs, :applied_patch_sha256, Map.get(attrs, "applied_patch_sha256"))
    matched_hunks = Map.get(attrs, :matched_hunks, Map.get(attrs, "matched_hunks", 0))
    unmatched_hunks = Map.get(attrs, :unmatched_hunks, Map.get(attrs, "unmatched_hunks", 0))
    human_edits? = Map.get(attrs, :human_edits, Map.get(attrs, "human_edits", false))
    tests_passed? = Map.get(attrs, :tests_passed, Map.get(attrs, "tests_passed", false))

    semantic_equivalence? =
      Map.get(attrs, :semantic_equivalence, Map.get(attrs, "semantic_equivalence", false))

    cond do
      is_binary(expected) and expected == applied ->
        "exact"

      human_edits? and tests_passed? and semantic_equivalence? ->
        "equivalent_with_human_edits"

      matched_hunks > 0 and unmatched_hunks > 0 ->
        "partial"

      is_binary(expected) and is_binary(applied) ->
        "divergent"

      true ->
        "unknown"
    end
  end

  def record!(attrs) when is_map(attrs) do
    classification = classify(attrs)

    %{
      "schema_version" => @schema_version,
      "equivalence_id" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :equivalence_id),
      "expected_patch_sha256" =>
        Map.get(attrs, :expected_patch_sha256, Map.get(attrs, "expected_patch_sha256")),
      "applied_patch_sha256" =>
        Map.get(attrs, :applied_patch_sha256, Map.get(attrs, "applied_patch_sha256")),
      "classification" => classification,
      "matched_hunks" => Map.get(attrs, :matched_hunks, Map.get(attrs, "matched_hunks", 0)),
      "unmatched_hunks" => Map.get(attrs, :unmatched_hunks, Map.get(attrs, "unmatched_hunks", 0)),
      "human_edits" => Map.get(attrs, :human_edits, Map.get(attrs, "human_edits", false)),
      "tests_passed" => Map.get(attrs, :tests_passed, Map.get(attrs, "tests_passed", false)),
      "semantic_equivalence" =>
        Map.get(attrs, :semantic_equivalence, Map.get(attrs, "semantic_equivalence", false)),
      "finding_code" => "patch_equivalence_#{classification}"
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = record!(attrs)

    %{
      external_id: payload["equivalence_id"],
      name: payload["classification"],
      status: "active",
      payload: payload
    }
  end
end

defmodule Conveyor.Domain.PlanAudit do
  use Conveyor.Domain.ActiveResource, table: "plan_audits"
end

defmodule Conveyor.Domain.Epic do
  use Conveyor.Domain.ActiveResource, table: "epics"
end

defmodule Conveyor.Domain.Slice do
  use Conveyor.Domain.ActiveResource, table: "slices"
end

defmodule Conveyor.Domain.DiffPolicy do
  use Conveyor.Domain.ActiveResource, table: "diff_policies"
end

defmodule Conveyor.Domain.ReviewPolicy do
  use Conveyor.Domain.ActiveResource, table: "review_policies"
end

defmodule Conveyor.Domain.AgentBrief do
  use Conveyor.Domain.ActiveResource, table: "agent_briefs"
end

defmodule Conveyor.Domain.ContractLock do
  use Conveyor.Domain.ActiveResource, table: "contract_locks"
end

defmodule Conveyor.Domain.TestPack do
  use Conveyor.Domain.ActiveResource, table: "test_packs"
end

defmodule Conveyor.Domain.VerificationSuite do
  use Conveyor.Domain.ActiveResource, table: "verification_suites"
end

defmodule Conveyor.Domain.TestPackCalibration do
  use Conveyor.Domain.ActiveResource, table: "test_pack_calibrations"
end

defmodule Conveyor.Domain.ContextPack do
  use Conveyor.Domain.ActiveResource, table: "context_packs"
end

defmodule Conveyor.Domain.InstructionSource do
  use Conveyor.Domain.ActiveResource, table: "instruction_sources"
end

defmodule Conveyor.Domain.CodeQualityRun do
  use Conveyor.Domain.ActiveResource, table: "code_quality_runs"
end

defmodule Conveyor.Domain.RunPrompt do
  use Conveyor.Domain.ActiveResource, table: "run_prompts"
end

defmodule Conveyor.Domain.RunSpec do
  use Conveyor.Domain.ActiveResource, table: "run_specs", update_accept: [:name, :status]

  @schema_version "run_spec@1"
  @station_plan_version "station_plan@1"
  @digest_keys [
    "project",
    "base_commit",
    "slice",
    "autonomy_level",
    "plan",
    "decision",
    "agent_brief",
    "contract_lock",
    "agents",
    "policy",
    "diff_policy",
    "test_pack",
    "verification",
    "prompt",
    "agent_profile",
    "toolchain",
    "sandbox",
    "budget",
    "code_quality",
    "canary",
    "schema",
    "station_plan"
  ]

  def schema_version, do: @schema_version
  def station_plan_version, do: @station_plan_version
  def digest_keys, do: @digest_keys

  def build!(attrs) when is_map(attrs) do
    contract_digests =
      attrs
      |> fetch_required!(:contract_digests)
      |> normalize_digest_set!()

    unsigned = %{
      "schema_version" => @schema_version,
      "run_id" => fetch_required!(attrs, :run_id),
      "project_id" => fetch_required!(attrs, :project_id),
      "base_commit" => fetch_required!(attrs, :base_commit),
      "slice_id" => fetch_required!(attrs, :slice_id),
      "autonomy_level" => fetch_required!(attrs, :autonomy_level),
      "contract_digests" => contract_digests,
      "stations" => normalize_stations!(fetch_required!(attrs, :stations))
    }

    run_spec_sha256 = sha256(unsigned)

    unsigned
    |> Map.put("run_spec_sha256", run_spec_sha256)
    |> Map.update!("stations", fn stations ->
      Enum.map(stations, &bind_station_io(&1, run_spec_sha256))
    end)
  end

  def create_attrs!(attrs) when is_map(attrs) do
    run_spec = build!(attrs)

    %{
      external_id: run_spec["run_spec_sha256"],
      name: run_spec["run_id"],
      status: "active",
      payload: run_spec
    }
  end

  def digest_summary(run_spec) when is_map(run_spec) do
    contract_digests = Map.fetch!(run_spec, "contract_digests")

    %{
      schema_version: "conveyor.run_spec_digest_summary@1",
      category: "run_spec_digest_set",
      run_id: run_spec["run_id"],
      run_spec_sha256: run_spec["run_spec_sha256"],
      digest_count: map_size(contract_digests),
      digest_keys: Map.keys(contract_digests),
      station_keys: Enum.map(run_spec["stations"], & &1["station_key"])
    }
  end

  def diff_finding(old_run_spec, new_run_spec)
      when is_map(old_run_spec) and is_map(new_run_spec) do
    changed_keys =
      @digest_keys
      |> Enum.filter(fn key ->
        get_in(old_run_spec, ["contract_digests", key]) !=
          get_in(new_run_spec, ["contract_digests", key])
      end)

    %{
      schema_version: "conveyor.run_spec_diff@1",
      category: "run_spec_contract_change",
      finding_code: "contract_change_requires_new_run_spec_and_run_attempt",
      action: "create_new_run_spec_and_run_attempt",
      old_run_spec_sha256: old_run_spec["run_spec_sha256"],
      new_run_spec_sha256: new_run_spec["run_spec_sha256"],
      changed_digest_keys: changed_keys
    }
  end

  def equivalent?(left_run_spec, right_run_spec)
      when is_map(left_run_spec) and is_map(right_run_spec) do
    left_run_spec["run_spec_sha256"] == right_run_spec["run_spec_sha256"]
  end

  defp normalize_digest_set!(digest_set) when is_map(digest_set) do
    normalized =
      digest_set
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    missing = @digest_keys -- Map.keys(normalized)

    if missing == [] do
      Map.take(normalized, @digest_keys)
    else
      raise ArgumentError, "missing RunSpec digest keys: #{Enum.join(missing, ", ")}"
    end
  end

  defp normalize_digest_set!(_digest_set) do
    raise ArgumentError, "RunSpec contract_digests must be a map"
  end

  defp normalize_stations!(stations) when is_list(stations) and stations != [] do
    Enum.map(stations, fn station ->
      %{
        "schema_version" => @station_plan_version,
        "station_key" => fetch_required!(station, :station_key),
        "intent" => fetch_required!(station, :intent),
        "inputs" =>
          normalize_map!(Map.get(station, :inputs) || Map.get(station, "inputs") || %{}),
        "outputs" =>
          normalize_map!(Map.get(station, :outputs) || Map.get(station, "outputs") || %{})
      }
    end)
  end

  defp normalize_stations!(_stations) do
    raise ArgumentError, "RunSpec stations must be a non-empty list"
  end

  defp bind_station_io(station, run_spec_sha256) do
    station
    |> Map.update!("inputs", &Map.put(&1, "run_spec_sha256", run_spec_sha256))
    |> Map.update!("outputs", &Map.put(&1, "run_spec_sha256", run_spec_sha256))
  end

  defp normalize_map!(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map!(_map) do
    raise ArgumentError, "RunSpec station inputs and outputs must be maps"
  end

  defp fetch_required!(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key)) ||
      raise ArgumentError, "missing required RunSpec field: #{key}"
  end

  defp sha256(payload) do
    digest =
      :crypto.hash(:sha256, canonical_json(payload))
      |> Base.encode16(case: :lower)

    "sha256:#{digest}"
  end

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(key) <> ":" <> canonical_json(value)
    end)
    |> then(&"{#{&1}}")
  end

  defp canonical_json(list) when is_list(list) do
    list
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&"[#{&1}]")
  end

  defp canonical_json(value), do: Jason.encode!(value)
end

defmodule Conveyor.Domain.WorkspaceMaterialization do
  use Conveyor.Domain.ActiveResource, table: "workspace_materializations"
end

defmodule Conveyor.Domain.AgentProfile do
  use Conveyor.Domain.ActiveResource, table: "agent_profiles"
end

defmodule Conveyor.Domain.RunAttempt do
  use Conveyor.Domain.ActiveResource, table: "run_attempts"
end

defmodule Conveyor.Domain.AgentSession do
  use Conveyor.Domain.ActiveResource, table: "agent_sessions"
end

defmodule Conveyor.Domain.PatchSet do
  use Conveyor.Domain.ActiveResource, table: "patch_sets"
end

defmodule Conveyor.Domain.RiskAssessment do
  use Conveyor.Domain.ActiveResource, table: "risk_assessments"
end

defmodule Conveyor.Domain.StationRun do
  use Conveyor.Domain.ActiveResource, table: "station_runs"
end

defmodule Conveyor.Domain.Evidence do
  use Conveyor.Domain.ActiveResource, table: "evidence"
end

defmodule Conveyor.Domain.ToolInvocation do
  use Conveyor.Domain.ActiveResource, table: "tool_invocations"
end

defmodule Conveyor.Domain.Review do
  use Conveyor.Domain.ActiveResource, table: "reviews"
end

defmodule Conveyor.Domain.GateResult do
  use Conveyor.Domain.ActiveResource, table: "gate_results"
end

defmodule Conveyor.Domain.Artifact do
  use Conveyor.Domain.ActiveResource, table: "artifacts"

  @schema_version "conveyor.artifact@1"
  @sensitivity_levels ["public", "internal", "confidential", "secret"]

  def sensitivity_levels, do: @sensitivity_levels

  def build!(attrs) when is_map(attrs) do
    content = Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :content)
    sensitivity = Map.get(attrs, :sensitivity, Map.get(attrs, "sensitivity", "internal"))

    if sensitivity not in @sensitivity_levels do
      raise ArgumentError, "unknown artifact sensitivity: #{inspect(sensitivity)}"
    end

    %{
      "schema_version" => @schema_version,
      "artifact_key" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :artifact_key),
      "sha256" => Conveyor.Domain.PayloadHelpers.sha256_binary(content),
      "size_bytes" => byte_size(content),
      "content_type" =>
        Map.get(attrs, :content_type, Map.get(attrs, "content_type", "application/octet-stream")),
      "sensitivity" => sensitivity,
      "blob_uri" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :blob_uri),
      "metadata" =>
        attrs
        |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
        |> Conveyor.Domain.PayloadHelpers.normalize_map()
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["sha256"],
      name: payload["artifact_key"],
      status: "active",
      payload: payload
    }
  end

  def summary(payload) when is_map(payload) do
    %{
      schema_version: "conveyor.artifact_summary@1",
      category: "content_addressed_artifact",
      artifact_key: payload["artifact_key"],
      sha256: payload["sha256"],
      sensitivity: payload["sensitivity"],
      size_bytes: payload["size_bytes"]
    }
  end
end

defmodule Conveyor.Domain.RunBundle do
  use Conveyor.Domain.ActiveResource, table: "run_bundles"

  @schema_version "conveyor.run_bundle@1"

  def build!(attrs) when is_map(attrs) do
    artifacts =
      attrs
      |> Conveyor.Domain.PayloadHelpers.fetch_required!(:artifacts)
      |> Enum.map(&artifact_sha256!/1)
      |> Enum.sort()

    unsigned = %{
      "schema_version" => @schema_version,
      "bundle_key" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :bundle_key),
      "run_spec_sha256" =>
        Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :run_spec_sha256),
      "artifact_sha256s" => artifacts,
      "metadata" =>
        attrs
        |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
        |> Conveyor.Domain.PayloadHelpers.normalize_map()
    }

    Map.put(
      unsigned,
      "run_bundle_sha256",
      Conveyor.Domain.PayloadHelpers.canonical_sha256(unsigned)
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["run_bundle_sha256"],
      name: payload["bundle_key"],
      status: "active",
      payload: payload
    }
  end

  def summary(payload) when is_map(payload) do
    %{
      schema_version: "conveyor.run_bundle_summary@1",
      category: "run_bundle_projection",
      bundle_key: payload["bundle_key"],
      run_bundle_sha256: payload["run_bundle_sha256"],
      run_spec_sha256: payload["run_spec_sha256"],
      artifact_count: length(payload["artifact_sha256s"] || [])
    }
  end

  defp artifact_sha256!(artifact) when is_binary(artifact), do: artifact

  defp artifact_sha256!(artifact) when is_map(artifact) do
    Map.get(artifact, "sha256") || Map.get(artifact, :sha256) ||
      raise ArgumentError, "artifact is missing sha256"
  end
end

defmodule Conveyor.Domain.ReviewerHealth do
  use Conveyor.Domain.ActiveResource, table: "reviewer_health"
end

defmodule Conveyor.Domain.GateHealth do
  use Conveyor.Domain.ActiveResource, table: "gate_health"
end

defmodule Conveyor.Domain.LedgerEvent do
  @moduledoc """
  Append-only audit event for the R0 Conveyor timeline.

  Ash/Postgres resources remain state truth. Ledger events are immutable
  evidence for human-readable replay, idempotency, and downstream outbox
  observers.
  """

  use Ash.Resource,
    otp_app: :conveyor,
    domain: Conveyor.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("ledger_events")
    repo(Conveyor.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :external_id,
        :name,
        :status,
        :payload,
        :idempotency_key,
        :trace_id,
        :span_id,
        :stream_id,
        :event_type,
        :occurred_at,
        :summary,
        :metadata
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :external_id, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :status, :string do
      allow_nil?(false)
      public?(true)
      default("active")
      constraints(match: ~r/^(active|paused|archived)$/)
    end

    attribute :payload, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :idempotency_key, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :trace_id, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :span_id, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :stream_id, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :event_type, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :summary, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    create_timestamp :inserted_at do
      public?(true)
    end

    update_timestamp :updated_at do
      public?(true)
    end
  end

  identities do
    identity(:unique_external_id, [:external_id])
    identity(:unique_idempotency_key, [:idempotency_key])
  end
end

defmodule Conveyor.Domain.Policy do
  use Conveyor.Domain.ActiveResource, table: "policies"
end

defmodule Conveyor.Domain.RetentionPolicy do
  use Conveyor.Domain.ActiveResource, table: "retention_policies"

  @schema_version "conveyor.retention_policy@1"
  @decisions ["retain", "eligible_for_review", "requires_human_approval"]

  def decisions, do: @decisions

  def build!(attrs) when is_map(attrs) do
    %{
      "schema_version" => @schema_version,
      "policy_key" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :policy_key),
      "retain_for_days" =>
        Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :retain_for_days),
      "sensitivity" => Map.get(attrs, :sensitivity, Map.get(attrs, "sensitivity", "internal")),
      "delete_requires_human_approval" =>
        Map.get(
          attrs,
          :delete_requires_human_approval,
          Map.get(attrs, "delete_requires_human_approval", true)
        ),
      "metadata" =>
        attrs
        |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
        |> Conveyor.Domain.PayloadHelpers.normalize_map()
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["policy_key"],
      name: payload["policy_key"],
      status: "active",
      payload: payload
    }
  end

  def decision(policy_payload, artifact_payload)
      when is_map(policy_payload) and is_map(artifact_payload) do
    cond do
      policy_payload["delete_requires_human_approval"] ->
        "requires_human_approval"

      artifact_payload["sensitivity"] in ["confidential", "secret"] ->
        "eligible_for_review"

      true ->
        "retain"
    end
  end
end

defmodule Conveyor.Domain.RunBudget do
  use Conveyor.Domain.ActiveResource, table: "run_budgets"
end

defmodule Conveyor.Domain.Incident do
  use Conveyor.Domain.ActiveResource, table: "incidents"
end

defmodule Conveyor.Domain.StationEffect do
  use Conveyor.Domain.ActiveResource, table: "station_effects"
end

defmodule Conveyor.Domain.CredentialLease do
  use Conveyor.Domain.ActiveResource, table: "credential_leases"
end
