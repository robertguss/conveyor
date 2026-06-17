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
  @execution_resources [
    Conveyor.Domain.RunAttempt,
    Conveyor.Domain.AgentSession,
    Conveyor.Domain.PatchSet,
    Conveyor.Domain.RiskAssessment,
    Conveyor.Domain.StationRun,
    Conveyor.Domain.Evidence,
    Conveyor.Domain.ToolInvocation,
    Conveyor.Domain.Review,
    Conveyor.Domain.GateResult,
    Conveyor.Domain.CodeQualityRun,
    Conveyor.Domain.WorkspaceMaterialization
  ]
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
  def execution_resources, do: @execution_resources

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

  def normalize_list(values) when is_list(values), do: Enum.map(values, &normalize_payload/1)
  def normalize_list(_values), do: raise(ArgumentError, "payload value must be a list")

  def normalize_payload(%DateTime{} = datetime), do: iso8601(datetime)
  def normalize_payload(value), do: normalize_value(value)

  def get(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

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

  defp normalize_value(%DateTime{} = datetime), do: iso8601(datetime)
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

defmodule Conveyor.Domain.ExecutionPayload do
  @moduledoc false

  alias Conveyor.Domain.PayloadHelpers

  def build!(schema_version, attrs, required_keys, optional_defaults \\ %{}, optional_keys \\ [])
      when is_map(attrs) do
    required =
      Map.new(required_keys, fn key ->
        {to_string(key), attrs |> PayloadHelpers.fetch_required!(key) |> normalize()}
      end)

    with_defaults =
      Enum.reduce(optional_defaults, required, fn {key, default}, acc ->
        Map.put(acc, to_string(key), attrs |> PayloadHelpers.get(key, default) |> normalize())
      end)

    optional =
      Enum.reduce(optional_keys, with_defaults, fn key, acc ->
        case PayloadHelpers.get(attrs, key) do
          nil -> acc
          value -> Map.put(acc, to_string(key), normalize(value))
        end
      end)

    Map.put(optional, "schema_version", schema_version)
  end

  def create_attrs!(payload, id_key, name_key) when is_map(payload) do
    %{
      external_id: fetch_payload!(payload, id_key),
      name: payload |> fetch_payload!(name_key) |> to_string(),
      status: "active",
      payload: payload
    }
  end

  defp fetch_payload!(payload, key) do
    Map.fetch!(payload, to_string(key))
  end

  defp normalize(value), do: PayloadHelpers.normalize_payload(value)
end

defmodule Conveyor.Domain.StateMachine do
  @moduledoc false

  alias Conveyor.Domain.PayloadHelpers
  alias Conveyor.Ledger
  alias Conveyor.Repo

  @schema_version "conveyor.domain_state_machine@1"

  def transition(resource, record, machine, transition, context \\ %{}, opts \\ [])
      when is_atom(resource) and is_map(machine) and is_map(context) do
    transition = to_string(transition)
    payload = payload(record)
    current_state = current_state(payload, machine)
    context = normalize_context(context)

    with {:ok, rule} <- transition_rule(resource, machine, transition, current_state, context),
         {:ok, guard_results} <-
           guard_results(resource, machine, transition, current_state, rule, context) do
      next_state = Map.fetch!(rule, :to)

      updated_payload =
        transition_payload(payload, machine, transition, current_state, next_state)

      log =
        transition_log(
          resource,
          record,
          machine,
          transition,
          current_state,
          next_state,
          guard_results
        )

      Repo.transaction(fn ->
        with {:ok, updated_record, notifications} <-
               Ash.update(record, %{payload: updated_payload},
                 action: :update,
                 return_notifications?: true
               ),
             {:ok, event, outbox_entries} <-
               Ledger.append_event(
                 ledger_event(
                   resource,
                   record,
                   transition,
                   current_state,
                   next_state,
                   log,
                   context,
                   opts
                 ),
                 channels: Keyword.get(opts, :channels, ["timeline"])
               ) do
          {updated_record, event, outbox_entries, Map.put(log, :ledger_event_id, event.id),
           notifications}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {updated_record, event, outbox_entries, transition_log, notifications}} ->
          Ash.Notifier.notify(notifications)
          {:ok, updated_record, event, outbox_entries, transition_log}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp transition_rule(resource, machine, transition, current_state, context) do
    case machine.transitions[transition] do
      nil ->
        {:error,
         rejected_transition(
           resource,
           machine,
           transition,
           current_state,
           nil,
           "unknown_transition",
           "No transition named #{transition} is configured.",
           context
         )}

      rule ->
        if allowed_from?(current_state, Map.fetch!(rule, :from)) do
          {:ok, rule}
        else
          {:error,
           rejected_transition(
             resource,
             machine,
             transition,
             current_state,
             Map.fetch!(rule, :to),
             "illegal_transition",
             "Transition #{transition} cannot move #{inspect(resource)} from #{current_state}.",
             context
           )}
        end
    end
  end

  defp guard_results(resource, machine, transition, current_state, rule, context) do
    Enum.reduce_while(Map.get(rule, :guards, []), {:ok, []}, fn guard, {:ok, results} ->
      case evaluate_guard(guard, context) do
        {:ok, result} ->
          {:cont, {:ok, [result | results]}}

        {:error, result} ->
          finding =
            rejected_transition(
              resource,
              machine,
              transition,
              current_state,
              Map.fetch!(rule, :to),
              "guard_failed",
              result.explanation,
              context
            )
            |> Map.put(:guard, result.guard)

          {:halt, {:error, finding}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, finding} -> {:error, finding}
    end
  end

  defp evaluate_guard(guard, context) do
    guard = to_string(guard)

    passed? =
      case guard do
        "plan_ready" ->
          truthy?(context["plan_ready"]) || context["readiness"] == "ready" ||
            context["plan_status"] in ["handoff_ready", "active", "completed"]

        "contract_locked" ->
          truthy?(context["contract_locked"]) || present?(context["contract_lock_id"]) ||
            present?(context["contract_lock_sha256"]) || present?(context["lock_ref"])

        "actor_separated" ->
          truthy?(context["actor_separated"]) || separated_actors?(context)

        "artifacts_present" ->
          truthy?(context["artifacts_present"]) || present?(context["artifact_refs"]) ||
            present?(context["artifacts"]) || present?(context["evidence_refs"])

        "gate_complete" ->
          truthy?(context["gate_complete"]) || context["gate_status"] in ["pass", "passed"] ||
            context["gate_decision"] in ["pass", "passed"]

        "autonomy_allowed" ->
          truthy?(context["autonomy_allowed"]) ||
            context["autonomy_policy"] in ["allow", "allowed"]

        "review_approved" ->
          truthy?(context["review_approved"]) ||
            context["review_decision"] in ["approve", "approved"]

        "reason_present" ->
          present?(context["reason"])

        other ->
          truthy?(context[other])
      end

    result = %{
      guard: guard,
      status: if(passed?, do: "passed", else: "failed"),
      explanation: guard_explanation(guard)
    }

    if passed?, do: {:ok, result}, else: {:error, result}
  end

  defp transition_payload(payload, machine, transition, current_state, next_state) do
    transition_record = %{
      "schema_version" => @schema_version,
      "category" => "domain_state_transition",
      "transition" => transition,
      "from_state" => current_state,
      "to_state" => next_state
    }

    payload =
      payload
      |> put_status_alias(machine, next_state)
      |> Map.put(machine.state_key, next_state)
      |> Map.put("lifecycle_state", next_state)

    Map.update(payload, "transition_log", [transition_record], &(&1 ++ [transition_record]))
  end

  defp transition_log(
         resource,
         record,
         machine,
         transition,
         current_state,
         next_state,
         guard_results
       ) do
    %{
      schema_version: @schema_version,
      category: "domain_state_transition",
      resource: inspect(resource),
      external_id: external_id(record),
      state_key: machine.state_key,
      transition: transition,
      from_state: current_state,
      to_state: next_state,
      guard_results: guard_results
    }
  end

  defp rejected_transition(
         resource,
         machine,
         transition,
         current_state,
         next_state,
         category,
         explanation,
         context
       ) do
    %{
      schema_version: @schema_version,
      category: "rejected_transition_guard",
      failure_category: category,
      resource: inspect(resource),
      external_id: context["external_id"],
      state_key: machine.state_key,
      transition: transition,
      from_state: current_state,
      to_state: next_state,
      explanation: explanation,
      context_keys: Map.keys(context)
    }
  end

  defp ledger_event(resource, record, transition, current_state, next_state, log, context, opts) do
    resource_name = resource_name(resource)
    external_id = external_id(record)

    %{
      idempotency_key:
        Keyword.get(opts, :idempotency_key) ||
          context["idempotency_key"] ||
          PayloadHelpers.canonical_sha256(%{
            "resource" => inspect(resource),
            "external_id" => external_id,
            "transition" => transition,
            "from_state" => current_state,
            "to_state" => next_state
          }),
      trace_id: Keyword.get(opts, :trace_id) || context["trace_id"] || "trace-#{external_id}",
      span_id: Keyword.get(opts, :span_id) || context["span_id"] || "span-#{transition}",
      stream_id: Keyword.get(opts, :stream_id) || context["stream_id"] || external_id,
      event_type: "domain_state_transition.#{resource_name}.#{transition}",
      summary:
        "#{inspect(resource)} #{external_id} #{current_state}->#{next_state} via #{transition}",
      payload: PayloadHelpers.normalize_map(log),
      metadata: %{
        "resource" => inspect(resource),
        "transition" => transition,
        "from_state" => current_state,
        "to_state" => next_state
      }
    }
  end

  defp current_state(payload, machine) do
    Map.get(payload, machine.state_key) || Map.get(payload, "lifecycle_state") ||
      machine.initial_state
  end

  defp allowed_from?(current_state, allowed) when is_list(allowed) do
    "*" in allowed || current_state in allowed
  end

  defp allowed_from?(_current_state, "*"), do: true
  defp allowed_from?(current_state, allowed), do: current_state == allowed

  defp separated_actors?(context) do
    actor = context["actor"] || context["reviewer"] || context["approver"]
    previous_actor = context["previous_actor"] || context["author"] || context["requester"]

    present?(actor) and present?(previous_actor) and actor != previous_actor
  end

  defp guard_explanation("plan_ready"), do: "Plan readiness evidence is required."
  defp guard_explanation("contract_locked"), do: "A current contract lock is required."

  defp guard_explanation("actor_separated"),
    do: "The same actor cannot perform both sides of this transition."

  defp guard_explanation("artifacts_present"), do: "Artifact or evidence references are required."
  defp guard_explanation("gate_complete"), do: "Gate completion evidence is required."
  defp guard_explanation("autonomy_allowed"), do: "Autonomy policy must allow this transition."
  defp guard_explanation("review_approved"), do: "An approved review decision is required."
  defp guard_explanation("reason_present"), do: "A transition reason is required."
  defp guard_explanation(guard), do: "Guard #{guard} did not pass."

  defp normalize_context(context) do
    Map.new(context, fn {key, value} ->
      {to_string(key), PayloadHelpers.normalize_payload(value)}
    end)
  end

  defp payload(%{payload: payload}) when is_map(payload),
    do: PayloadHelpers.normalize_map(payload)

  defp payload(payload) when is_map(payload), do: PayloadHelpers.normalize_map(payload)

  defp external_id(%{external_id: external_id}) when is_binary(external_id), do: external_id
  defp external_id(record) when is_map(record), do: Map.fetch!(record, "external_id")

  defp resource_name(resource),
    do: resource |> Module.split() |> List.last() |> Macro.underscore()

  defp put_status_alias(payload, %{status_key: status_key}, next_state) do
    Map.put(payload, status_key, next_state)
  end

  defp put_status_alias(payload, _machine, _next_state), do: payload

  defp truthy?(value), do: value in [true, "true", "yes", "allow", "allowed", "pass", "passed"]
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(nil), do: false
  defp present?(_value), do: true
end

defmodule Conveyor.Domain.ExecutionResources do
  @moduledoc """
  Payload-level association helpers for execution resources.

  The Phase 0 schema stores most execution references inside resource payloads.
  These summaries make those associations auditable until later beads promote
  selected references into dedicated relational columns.
  """

  @schema_version "conveyor.execution_association_summary@1"

  def association_summary(attrs) when is_map(attrs) do
    run_attempts = payloads(attrs, :run_attempts)
    station_runs = payloads(attrs, :station_runs)
    agent_sessions = payloads(attrs, :agent_sessions)
    patch_sets = payloads(attrs, :patch_sets)
    tool_invocations = payloads(attrs, :tool_invocations)
    reviews = payloads(attrs, :reviews)
    gate_results = payloads(attrs, :gate_results)
    evidence = payloads(attrs, :evidence)
    code_quality_runs = payloads(attrs, :code_quality_runs)
    workspace_materializations = payloads(attrs, :workspace_materializations)
    risk_assessments = payloads(attrs, :risk_assessments)

    %{
      schema_version: @schema_version,
      category: "execution_resource_association",
      slice_attempts: slice_attempts(run_attempts),
      run_attempt_ids: values(run_attempts, "run_attempt_id"),
      station_runs: project(station_runs, ["station_run_id", "run_attempt_id", "station_key"]),
      agent_sessions:
        project(agent_sessions, [
          "agent_session_id",
          "run_attempt_id",
          "station_run_id",
          "adapter",
          "session_role"
        ]),
      patch_sets: project(patch_sets, ["patch_set_id", "run_attempt_id", "station_run_id"]),
      tool_invocations:
        project(tool_invocations, [
          "tool_invocation_id",
          "run_attempt_id",
          "station_run_id",
          "agent_session_id"
        ]),
      review_ids: values(reviews, "review_id"),
      gate_result_ids: values(gate_results, "gate_result_id"),
      evidence_ids: values(evidence, "evidence_id"),
      code_quality_run_ids: values(code_quality_runs, "code_quality_run_id"),
      workspace_materialization_ids: values(workspace_materializations, "workspace_id"),
      risk_assessment_ids: values(risk_assessments, "risk_assessment_id"),
      independently_queryable: ["reviews", "gate_results"]
    }
  end

  defp payloads(attrs, key) do
    attrs
    |> Conveyor.Domain.PayloadHelpers.get(key, [])
    |> Enum.map(&payload/1)
  end

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(payload) when is_map(payload), do: payload

  defp slice_attempts(run_attempts) do
    run_attempts
    |> Enum.group_by(&Map.fetch!(&1, "slice_id"))
    |> Enum.map(fn {slice_id, attempts} ->
      %{
        slice_id: slice_id,
        attempt_count: length(attempts),
        run_attempt_ids: values(attempts, "run_attempt_id")
      }
    end)
    |> Enum.sort_by(& &1.slice_id)
  end

  defp project(payloads, keys) do
    Enum.map(payloads, fn payload -> Map.take(payload, keys) end)
  end

  defp values(payloads, key), do: Enum.map(payloads, &Map.fetch!(&1, key))
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

  @schema_version "conveyor.plan@1"
  @states ["draft", "audited", "handoff_ready", "active", "completed"]
  @transitions %{
    "audit" => %{from: "draft", to: "audited", guards: ["artifacts_present"]},
    "prepare_handoff" => %{
      from: "audited",
      to: "handoff_ready",
      guards: ["plan_ready", "contract_locked"]
    },
    "activate" => %{
      from: "handoff_ready",
      to: "active",
      guards: ["actor_separated", "autonomy_allowed"]
    },
    "complete" => %{from: "active", to: "completed", guards: ["gate_complete"]}
  }
  @state_machine %{state_key: "plan_state", initial_state: "draft", transitions: @transitions}

  def lifecycle_states, do: @states
  def transition_rules, do: @transitions

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:plan_id],
      %{plan_state: "draft"},
      [:title, :summary, :requirement_ids, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:plan_id, :plan_id)
  end

  def transition(record, transition, context \\ %{}, opts \\ []) do
    Conveyor.Domain.StateMachine.transition(
      __MODULE__,
      record,
      @state_machine,
      transition,
      context,
      opts
    )
  end
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

  @schema_version "conveyor.slice@1"
  @states [
    "drafted",
    "approved",
    "ready",
    "in_progress",
    "gated",
    "integrated",
    "done",
    "rejected",
    "blocked",
    "cancelled"
  ]
  @transitions %{
    "approve" => %{from: "drafted", to: "approved", guards: ["actor_separated"]},
    "ready" => %{
      from: "approved",
      to: "ready",
      guards: ["plan_ready", "contract_locked", "artifacts_present"]
    },
    "start" => %{from: "ready", to: "in_progress", guards: ["autonomy_allowed"]},
    "gate" => %{from: "in_progress", to: "gated", guards: ["gate_complete"]},
    "integrate" => %{
      from: "gated",
      to: "integrated",
      guards: ["review_approved", "artifacts_present"]
    },
    "finish" => %{from: "integrated", to: "done", guards: []},
    "reject" => %{from: ["drafted", "approved"], to: "rejected", guards: ["reason_present"]},
    "block" => %{
      from: ["approved", "ready", "in_progress"],
      to: "blocked",
      guards: ["reason_present"]
    },
    "cancel" => %{
      from: ["ready", "in_progress", "gated"],
      to: "cancelled",
      guards: ["reason_present"]
    }
  }
  @state_machine %{state_key: "slice_state", initial_state: "drafted", transitions: @transitions}

  def lifecycle_states, do: @states
  def transition_rules, do: @transitions

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:slice_id, :plan_id],
      %{slice_state: "drafted"},
      [:title, :requirement_ids, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:slice_id, :slice_id)
  end

  def transition(record, transition, context \\ %{}, opts \\ []) do
    Conveyor.Domain.StateMachine.transition(
      __MODULE__,
      record,
      @state_machine,
      transition,
      context,
      opts
    )
  end
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

  @schema_version "conveyor.code_quality_run@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:code_quality_run_id, :run_attempt_id, :station_run_id, :adapter, :decision],
      %{quality_status: "completed"},
      [:findings, :artifact_refs, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:code_quality_run_id, :adapter)
  end
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

    unsigned =
      %{
        "schema_version" => @schema_version,
        "run_id" => fetch_required!(attrs, :run_id),
        "project_id" => fetch_required!(attrs, :project_id),
        "base_commit" => fetch_required!(attrs, :base_commit),
        "slice_id" => fetch_required!(attrs, :slice_id),
        "autonomy_level" => fetch_required!(attrs, :autonomy_level),
        "contract_digests" => contract_digests,
        "stations" => normalize_stations!(fetch_required!(attrs, :stations))
      }
      |> maybe_put_capability_snapshot(attrs)
      |> validate_agent_profile_ceiling!()

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

  defp maybe_put_capability_snapshot(run_spec, attrs) do
    case Map.get(attrs, :agent_profile_capability_snapshot) ||
           Map.get(attrs, "agent_profile_capability_snapshot") do
      nil ->
        run_spec

      snapshot ->
        normalized_snapshot = Conveyor.AgentRunner.normalize_capability_snapshot!(snapshot)

        run_spec
        |> Map.put("agent_profile_capability_snapshot", normalized_snapshot)
        |> Map.put("negative_agent_capabilities", normalized_snapshot["negative_capabilities"])
        |> Map.put(
          "agent_profile_autonomy_ceiling",
          normalized_snapshot["effective_autonomy_ceiling"]
        )
    end
  end

  defp validate_agent_profile_ceiling!(%{"agent_profile_autonomy_ceiling" => ceiling} = run_spec) do
    selected_level = Map.fetch!(run_spec, "autonomy_level")

    if Conveyor.AgentRunner.autonomy_allows?(selected_level, ceiling) do
      run_spec
    else
      raise ArgumentError,
            "RunSpec autonomy_level #{selected_level} exceeds agent profile ceiling #{ceiling}"
    end
  end

  defp validate_agent_profile_ceiling!(run_spec), do: run_spec

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

  @schema_version "conveyor.workspace_materialization@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:workspace_id, :run_attempt_id, :base_commit, :path_digest],
      %{materialized_at: nil},
      [:root_path, :container_image_digest, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:workspace_id, :run_attempt_id)
  end
end

defmodule Conveyor.Domain.AgentProfile do
  use Conveyor.Domain.ActiveResource, table: "agent_profiles"

  @schema_version "conveyor.agent_profile@1"

  def build!(attrs) when is_map(attrs) do
    snapshot = Conveyor.AgentRunner.capability_snapshot(attrs)

    %{
      "schema_version" => @schema_version,
      "agent_profile_id" => snapshot["agent_profile_id"],
      "adapter" => snapshot["adapter"],
      "name" =>
        Conveyor.Domain.PayloadHelpers.get(
          attrs,
          :name,
          snapshot["agent_profile_id"]
        ),
      "capabilities" => snapshot["capabilities"],
      "negative_capabilities" => snapshot["negative_capabilities"],
      "known_limitations" => snapshot["known_limitations"],
      "capability_snapshot" => snapshot,
      "autonomy_ceiling" => snapshot["effective_autonomy_ceiling"],
      "metadata" =>
        attrs
        |> Conveyor.Domain.PayloadHelpers.get(:metadata, %{})
        |> Conveyor.Domain.PayloadHelpers.normalize_map()
    }
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["agent_profile_id"],
      name: payload["name"],
      status: "active",
      payload: payload
    }
  end
end

defmodule Conveyor.Domain.RunAttempt do
  use Conveyor.Domain.ActiveResource, table: "run_attempts"

  @schema_version "conveyor.run_attempt@1"
  @states [
    "planned",
    "running",
    "evidence_recorded",
    "reviewed",
    "gated",
    "reported",
    "failed",
    "cancelled"
  ]
  @transitions %{
    "start" => %{
      from: "planned",
      to: "running",
      guards: ["plan_ready", "contract_locked", "autonomy_allowed"]
    },
    "record_evidence" => %{
      from: "running",
      to: "evidence_recorded",
      guards: ["artifacts_present"]
    },
    "review" => %{
      from: "evidence_recorded",
      to: "reviewed",
      guards: ["actor_separated", "review_approved"]
    },
    "gate" => %{from: "reviewed", to: "gated", guards: ["gate_complete"]},
    "report" => %{from: "gated", to: "reported", guards: ["artifacts_present"]},
    "fail" => %{
      from: ["planned", "running", "evidence_recorded", "reviewed", "gated"],
      to: "failed",
      guards: ["reason_present"]
    },
    "cancel" => %{from: ["planned", "running"], to: "cancelled", guards: ["reason_present"]}
  }
  @state_machine %{
    state_key: "attempt_state",
    status_key: "attempt_status",
    initial_state: "planned",
    transitions: @transitions
  }

  def lifecycle_states, do: @states
  def transition_rules, do: @transitions

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:run_attempt_id, :slice_id, :run_spec_sha256, :attempt_number],
      %{attempt_state: "planned", attempt_status: "planned"},
      [:station_plan_sha256, :previous_run_attempt_id, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["run_attempt_id"],
      name: "#{payload["slice_id"]}##{payload["attempt_number"]}",
      status: "active",
      payload: payload
    }
  end

  def transition(record, transition, context \\ %{}, opts \\ []) do
    Conveyor.Domain.StateMachine.transition(
      __MODULE__,
      record,
      @state_machine,
      transition,
      context,
      opts
    )
  end
end

defmodule Conveyor.Domain.AgentSession do
  use Conveyor.Domain.ActiveResource, table: "agent_sessions"

  @schema_version "conveyor.agent_session@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [
        :agent_session_id,
        :run_attempt_id,
        :station_run_id,
        :adapter,
        :agent_profile_id,
        :started_at
      ],
      %{session_role: "adapter_output", session_status: "running"},
      [:completed_at, :transcript_ref, :capability_report, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:agent_session_id, :adapter)
  end
end

defmodule Conveyor.Domain.PatchSet do
  use Conveyor.Domain.ActiveResource, table: "patch_sets"

  @schema_version "conveyor.patch_set@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:patch_set_id, :run_attempt_id, :station_run_id, :diff_sha256],
      %{patch_status: "proposed"},
      [:base_commit, :summary, :files, :tool_invocation_ids, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:patch_set_id, :station_run_id)
  end
end

defmodule Conveyor.Domain.RiskAssessment do
  use Conveyor.Domain.ActiveResource, table: "risk_assessments"

  @schema_version "conveyor.risk_assessment@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:risk_assessment_id, :run_attempt_id, :station_run_id, :risk_level, :policy],
      %{},
      [:factors, :review_required, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:risk_assessment_id, :risk_level)
  end
end

defmodule Conveyor.Domain.StationRun do
  use Conveyor.Domain.ActiveResource, table: "station_runs"

  @schema_version "conveyor.station_run@1"
  @retry_decision_schema_version "conveyor.station_run_retry_decision@1"
  @idempotency_summary_schema_version "conveyor.station_run_idempotency_summary@1"

  def build!(attrs) when is_map(attrs) do
    payload =
      Conveyor.Domain.ExecutionPayload.build!(
        @schema_version,
        attrs,
        [
          :station_run_id,
          :run_attempt_id,
          :station_key,
          :station_spec_sha256,
          :attempt_number
        ],
        %{station_status: "planned"},
        [:input_sha256, :output_sha256, :metadata]
      )

    Map.put(
      payload,
      "idempotency_key",
      Conveyor.Domain.PayloadHelpers.get(attrs, :idempotency_key) || idempotency_key(payload)
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:station_run_id, :station_key)
  end

  def idempotency_key(attrs) when is_map(attrs) do
    Conveyor.Domain.PayloadHelpers.canonical_sha256(%{
      "kind" => "station_run_idempotency",
      "run_attempt_id" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :run_attempt_id),
      "station_key" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :station_key),
      "station_spec_sha256" =>
        Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :station_spec_sha256),
      "attempt_number" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :attempt_number)
    })
  end

  def retry_decision(existing_run, requested_run, effects \\ [])
      when is_map(existing_run) and is_map(requested_run) do
    existing = payload(existing_run)
    requested = build!(requested_run)
    unknown_effects = Conveyor.Domain.StationEffect.unknown_effects(effects)

    cond do
      unknown_effects != [] ->
        decision(
          existing,
          requested,
          "reconcile_unknown_effects_before_retry",
          "unknown_effects_present",
          false,
          unknown_effects
        )

      inputs_changed?(existing, requested) ->
        decision(
          existing,
          requested,
          "create_new_station_attempt",
          "station_inputs_changed",
          false
        )

      existing["station_status"] == "completed" ->
        decision(
          existing,
          requested,
          "resume_completed_station",
          "station_already_completed",
          true
        )

      existing["idempotency_key"] == requested["idempotency_key"] ->
        decision(existing, requested, "retry_station_run", "same_idempotency_key", true)

      true ->
        decision(
          existing,
          requested,
          "create_new_station_attempt",
          "idempotency_key_changed",
          false
        )
    end
  end

  def idempotency_summary(station_run, effects) when is_map(station_run) and is_list(effects) do
    run = payload(station_run)
    effect_payloads = Enum.map(effects, &Conveyor.Domain.StationEffect.payload/1)

    %{
      schema_version: @idempotency_summary_schema_version,
      category: "station_idempotency",
      station_run_id: run["station_run_id"],
      idempotency_key: run["idempotency_key"],
      output_sha256: run["output_sha256"],
      effect_states:
        Enum.map(effect_payloads, fn effect ->
          %{
            effect_id: effect["effect_id"],
            idempotency_key: effect["idempotency_key"],
            effect_status: effect["effect_status"],
            output_sha256: effect["output_sha256"]
          }
        end),
      unknown_effect_ids:
        effect_payloads
        |> Conveyor.Domain.StationEffect.unknown_effects()
        |> Enum.map(& &1["effect_id"])
    }
  end

  defp inputs_changed?(existing, requested) do
    existing["input_sha256"] != requested["input_sha256"] ||
      existing["station_spec_sha256"] != requested["station_spec_sha256"]
  end

  defp decision(existing, requested, action, reason, retry_safe, unknown_effects \\ []) do
    %{
      schema_version: @retry_decision_schema_version,
      category: "station_retry_decision",
      action: action,
      reason: reason,
      retry_safe: retry_safe,
      duplicate_artifacts: false,
      existing_station_run_id: existing["station_run_id"],
      requested_station_run_id: requested["station_run_id"],
      existing_idempotency_key: existing["idempotency_key"],
      requested_idempotency_key: requested["idempotency_key"],
      unknown_effect_ids: Enum.map(unknown_effects, & &1["effect_id"])
    }
  end

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(payload) when is_map(payload), do: payload
end

defmodule Conveyor.Domain.Evidence do
  use Conveyor.Domain.ActiveResource, table: "evidence"

  @schema_version "conveyor.evidence@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:evidence_id, :run_attempt_id, :station_run_id, :artifact_sha256, :evidence_type],
      %{},
      [:requirement_ids, :summary, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:evidence_id, :evidence_type)
  end
end

defmodule Conveyor.Domain.ToolInvocation do
  use Conveyor.Domain.ActiveResource, table: "tool_invocations"

  @schema_version "conveyor.tool_invocation@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [
        :tool_invocation_id,
        :run_attempt_id,
        :station_run_id,
        :agent_session_id,
        :command_ref,
        :started_at
      ],
      %{tool_status: "running"},
      [
        :completed_at,
        :exit_code,
        :artifact_refs,
        :policy_profile,
        :adapter_mode,
        :command_spec,
        :cwd,
        :env_keys,
        :network,
        :timeout_ms,
        :duration_ms,
        :output_refs,
        :output_sha256,
        :policy_decision,
        :transcript,
        :metadata
      ]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:tool_invocation_id, :command_ref)
  end
end

defmodule Conveyor.Domain.Review do
  use Conveyor.Domain.ActiveResource, table: "reviews"

  @schema_version "conveyor.review@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:review_id, :run_attempt_id, :station_run_id, :reviewer_profile_id, :decision],
      %{},
      [:findings, :evidence_refs, :gate_result_id, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:review_id, :decision)
  end
end

defmodule Conveyor.Domain.GateResult do
  use Conveyor.Domain.ActiveResource, table: "gate_results"

  @schema_version "conveyor.gate_result@1"

  def build!(attrs) when is_map(attrs) do
    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:gate_result_id, :run_attempt_id, :station_run_id, :decision, :suite_kind],
      %{},
      [:review_id, :evidence_refs, :finding_refs, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:gate_result_id, :decision)
  end
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

  @schema_version "conveyor.run_budget@1"
  @evaluation_schema_version "conveyor.run_budget_evaluation@1"
  @finding_schema_version "conveyor.run_budget_finding@1"
  @counter_keys [
    "wall_clock_ms",
    "idle_ms",
    "tool_calls",
    "command_count",
    "output_bytes",
    "repeated_command_failures",
    "same_file_rewrites",
    "no_diff_progress_ms",
    "tokens",
    "cost_micros"
  ]
  @stop_reasons %{
    "wall_clock_ms" => "wall_clock_exhausted",
    "idle_ms" => "heartbeat_without_progress",
    "tool_calls" => "tool_call_budget_exhausted",
    "command_count" => "command_count_exhausted",
    "output_bytes" => "output_flooding",
    "repeated_command_failures" => "repeated_identical_failures",
    "same_file_rewrites" => "same_file_rewrite_loop",
    "no_diff_progress_ms" => "no_patch_progress",
    "tokens" => "token_budget_exhausted",
    "cost_micros" => "cost_budget_exhausted"
  }

  def counter_keys, do: @counter_keys

  def build!(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put(
        :limits,
        attrs
        |> Conveyor.Domain.PayloadHelpers.fetch_required!(:limits)
        |> normalize_counters!(:limits)
      )
      |> Map.put(
        :consumed_counters,
        attrs
        |> Conveyor.Domain.PayloadHelpers.get(:consumed_counters, %{})
        |> normalize_counters!(:consumed_counters)
      )

    Conveyor.Domain.ExecutionPayload.build!(
      @schema_version,
      attrs,
      [:run_budget_id, :run_attempt_id, :limits],
      %{budget_status: "active"},
      [:station_run_id, :policy_profile, :consumed_counters, :metadata]
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    payload = build!(attrs)

    %{
      external_id: payload["run_budget_id"],
      name: payload["run_attempt_id"],
      status: "active",
      payload: payload
    }
  end

  def evaluate(run_budget, consumed_counters \\ %{})
      when is_map(run_budget) and is_map(consumed_counters) do
    budget = payload(run_budget)

    consumed =
      budget
      |> Map.get("consumed_counters", %{})
      |> Map.merge(normalize_counters!(consumed_counters, :consumed_counters))

    findings =
      budget
      |> Map.fetch!("limits")
      |> exceeded_findings(budget, consumed)

    %{
      schema_version: @evaluation_schema_version,
      category: "run_budget_evaluation",
      run_budget_id: budget["run_budget_id"],
      run_attempt_id: budget["run_attempt_id"],
      station_run_id: budget["station_run_id"],
      policy_profile: budget["policy_profile"],
      budget_status: evaluation_status(findings),
      policy_controlled_stop: findings != [],
      ordinary_agent_failure: false,
      consumed_counters: Map.take(consumed, @counter_keys),
      limit_counters: budget["limits"],
      stop_reasons: Enum.map(findings, & &1.stop_reason),
      findings: findings
    }
  end

  defp exceeded_findings(limits, budget, consumed) do
    @counter_keys
    |> Enum.flat_map(fn counter ->
      consumed_value = Map.get(consumed, counter, 0)

      case Map.fetch(limits, counter) do
        {:ok, limit} when consumed_value > limit ->
          [finding(budget, counter, consumed_value, limit)]

        _within_limit_or_unset ->
          []
      end
    end)
  end

  defp finding(budget, counter, consumed, limit) do
    %{
      schema_version: @finding_schema_version,
      category: "run_budget_stop",
      failure_category: "budget_exhausted",
      stop_reason: Map.fetch!(@stop_reasons, counter),
      counter: counter,
      consumed: consumed,
      limit: limit,
      run_budget_id: budget["run_budget_id"],
      run_attempt_id: budget["run_attempt_id"],
      policy_controlled_stop: true,
      ordinary_agent_failure: false,
      action: "stop_run_attempt"
    }
  end

  defp evaluation_status([]), do: "within_budget"
  defp evaluation_status([_ | _]), do: "policy_controlled_stop"

  defp normalize_counters!(counters, label) when is_map(counters) do
    Map.new(counters, fn {key, value} ->
      counter = to_string(key)

      if counter not in @counter_keys do
        raise ArgumentError, "unknown #{label} counter: #{counter}"
      end

      {counter, normalize_counter_value!(value, label, counter)}
    end)
  end

  defp normalize_counters!(_counters, label) do
    raise ArgumentError, "#{label} must be a map"
  end

  defp normalize_counter_value!(value, _label, _counter) when is_integer(value) and value >= 0 do
    value
  end

  defp normalize_counter_value!(value, label, counter) do
    raise ArgumentError,
          "#{label}.#{counter} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(payload) when is_map(payload), do: payload
end

defmodule Conveyor.Domain.Incident do
  use Conveyor.Domain.ActiveResource, table: "incidents"
end

defmodule Conveyor.Domain.StationEffect do
  use Conveyor.Domain.ActiveResource, table: "station_effects"

  @schema_version "conveyor.station_effect@1"

  def build!(attrs) when is_map(attrs) do
    payload =
      Conveyor.Domain.ExecutionPayload.build!(
        @schema_version,
        attrs,
        [:effect_id, :run_attempt_id, :station_run_id, :effect_type, :declared_at],
        %{effect_status: "declared"},
        [:external_ref, :output_sha256, :metadata]
      )

    Map.put(
      payload,
      "idempotency_key",
      Conveyor.Domain.PayloadHelpers.get(attrs, :idempotency_key) || idempotency_key(payload)
    )
  end

  def create_attrs!(attrs) when is_map(attrs) do
    attrs
    |> build!()
    |> Conveyor.Domain.ExecutionPayload.create_attrs!(:effect_id, :effect_type)
  end

  def idempotency_key(attrs) when is_map(attrs) do
    Conveyor.Domain.PayloadHelpers.canonical_sha256(%{
      "kind" => "station_effect_idempotency",
      "station_run_id" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :station_run_id),
      "effect_type" => Conveyor.Domain.PayloadHelpers.fetch_required!(attrs, :effect_type),
      "external_ref" => Conveyor.Domain.PayloadHelpers.get(attrs, :external_ref, ""),
      "output_sha256" => Conveyor.Domain.PayloadHelpers.get(attrs, :output_sha256, "")
    })
  end

  def unknown_effects(effects) when is_list(effects) do
    effects
    |> Enum.map(&payload/1)
    |> Enum.filter(&(&1["effect_status"] in ["unknown", "unreconciled"]))
  end

  def payload(%{payload: payload}) when is_map(payload), do: payload
  def payload(payload) when is_map(payload), do: payload
end

defmodule Conveyor.Domain.CredentialLease do
  use Conveyor.Domain.ActiveResource, table: "credential_leases"
end
