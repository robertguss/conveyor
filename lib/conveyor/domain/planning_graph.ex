defmodule Conveyor.Domain.PlanningGraph do
  @moduledoc """
  Builds the Phase 0/1 planning graph from human-authored plan data.

  The first implementation stores relationship shape in the existing resource
  payload columns. Later beads can promote specific payload fields into
  dedicated columns without changing the traceability contract exercised here.
  """

  @schema_version "conveyor.planning_graph@1"
  @summary_schema_version "conveyor.planning_traceability_summary@1"
  @finding_schema_version "conveyor.planning_traceability_finding@1"
  @brief_contract_version "agent_brief@1"

  @work_graph_resources [
    Conveyor.Domain.Plan,
    Conveyor.Domain.Requirement,
    Conveyor.Domain.HumanDecision,
    Conveyor.Domain.Epic,
    Conveyor.Domain.Slice,
    Conveyor.Domain.AgentBrief
  ]

  def schema_version, do: @schema_version
  def summary_schema_version, do: @summary_schema_version
  def finding_schema_version, do: @finding_schema_version
  def brief_contract_version, do: @brief_contract_version
  def work_graph_resources, do: @work_graph_resources

  def build!(attrs) when is_map(attrs) do
    plan_id = fetch_required!(attrs, :plan_id)

    requirements =
      attrs
      |> fetch_required!(:requirements)
      |> normalize_requirements!(plan_id)

    decisions =
      attrs
      |> fetch_required!(:human_decisions)
      |> normalize_decisions!(plan_id)

    epics =
      attrs
      |> fetch_required!(:epics)
      |> normalize_epics!(plan_id)

    agent_briefs =
      attrs
      |> fetch_required!(:agent_briefs)
      |> normalize_agent_briefs!(plan_id)

    slices =
      attrs
      |> fetch_required!(:slices)
      |> normalize_slices!(plan_id)

    %{
      "schema_version" => @schema_version,
      "plan" => %{
        "id" => plan_id,
        "title" => fetch_required!(attrs, :title),
        "summary" => fetch_required!(attrs, :summary),
        "phase" => fetch_required!(attrs, :phase),
        "requirement_keys" => Enum.map(requirements, & &1["key"]),
        "decision_ids" => Enum.map(decisions, & &1["id"]),
        "epic_ids" => Enum.map(epics, & &1["id"]),
        "slice_ids" => Enum.map(slices, & &1["id"]),
        "agent_brief_keys" => Enum.map(agent_briefs, &agent_brief_key/1)
      },
      "requirements" => requirements,
      "human_decisions" => decisions,
      "epics" => epics,
      "slices" => slices,
      "agent_briefs" => agent_briefs
    }
  end

  def create!(attrs) when is_map(attrs) do
    graph = build!(attrs)

    records = %{
      plan:
        create_record!(
          Conveyor.Domain.Plan,
          graph["plan"]["id"],
          graph["plan"]["title"],
          graph["plan"]
        ),
      requirements:
        Enum.map(graph["requirements"], fn requirement ->
          create_record!(
            Conveyor.Domain.Requirement,
            requirement["key"],
            requirement["title"],
            requirement
          )
        end),
      human_decisions:
        Enum.map(graph["human_decisions"], fn decision ->
          create_record!(
            Conveyor.Domain.HumanDecision,
            decision["id"],
            decision["title"],
            decision
          )
        end),
      epics:
        Enum.map(graph["epics"], fn epic ->
          create_record!(Conveyor.Domain.Epic, epic["id"], epic["title"], epic)
        end),
      slices:
        Enum.map(graph["slices"], fn slice ->
          create_record!(Conveyor.Domain.Slice, slice["id"], slice["goal"], slice)
        end),
      agent_briefs:
        Enum.map(graph["agent_briefs"], fn brief ->
          create_record!(
            Conveyor.Domain.AgentBrief,
            agent_brief_key(brief),
            brief["title"],
            brief
          )
        end)
    }

    %{graph: graph, records: records, summary: traceability_summary(graph)}
  end

  def traceability_summary(graph) when is_map(graph) do
    findings = orphan_findings(graph)
    briefs = Map.fetch!(graph, "agent_briefs")

    %{
      schema_version: @summary_schema_version,
      category: "planning_traceability",
      plan_id: get_in(graph, ["plan", "id"]),
      status: if(findings == [], do: "ok", else: "error"),
      requirement_count: length(Map.fetch!(graph, "requirements")),
      decision_count: length(Map.fetch!(graph, "human_decisions")),
      epic_count: length(Map.fetch!(graph, "epics")),
      slice_count: length(Map.fetch!(graph, "slices")),
      agent_brief_count: length(briefs),
      agent_brief_versions: Enum.map(briefs, &agent_brief_key/1),
      locked_agent_brief_versions:
        briefs
        |> Enum.filter(& &1["locked"])
        |> Enum.map(&agent_brief_key/1),
      rerun_agent_brief_versions:
        briefs |> Enum.filter(& &1["rerun_of"]) |> Enum.map(&agent_brief_key/1),
      slice_traceability: Enum.map(Map.fetch!(graph, "slices"), &slice_traceability/1),
      orphan_finding_count: length(findings),
      orphan_findings: findings
    }
  end

  def orphan_findings(graph) when is_map(graph) do
    requirement_keys = graph |> Map.fetch!("requirements") |> MapSet.new(& &1["key"])
    decision_ids = graph |> Map.fetch!("human_decisions") |> MapSet.new(& &1["id"])
    brief_keys = graph |> Map.fetch!("agent_briefs") |> MapSet.new(&agent_brief_key/1)

    graph
    |> Map.fetch!("slices")
    |> Enum.flat_map(fn slice ->
      missing_requirement_findings(slice, requirement_keys) ++
        missing_decision_findings(slice, decision_ids) ++
        missing_improvement_findings(slice) ++
        missing_agent_brief_findings(slice, brief_keys)
    end)
  end

  def lock_agent_brief!(brief) when is_map(brief) do
    brief
    |> normalize_agent_brief!("standalone")
    |> Map.put("locked", true)
  end

  def rerun_agent_brief!(brief, attrs \\ %{}) when is_map(brief) and is_map(attrs) do
    locked = lock_agent_brief!(brief)

    locked
    |> Map.put("version", fetch_required!(attrs, :version))
    |> Map.put("locked", false)
    |> Map.put("rerun_of", agent_brief_key(locked))
  end

  defp normalize_requirements!(requirements, plan_id)
       when is_list(requirements) and requirements != [] do
    Enum.map(requirements, fn requirement ->
      %{
        "schema_version" => "requirement@1",
        "plan_id" => plan_id,
        "key" => fetch_required!(requirement, :key),
        "title" => fetch_required!(requirement, :title),
        "acceptance_refs" =>
          normalize_string_list!(fetch_required!(requirement, :acceptance_refs))
      }
    end)
  end

  defp normalize_requirements!(_requirements, _plan_id) do
    raise ArgumentError, "planning graph requires at least one requirement"
  end

  defp normalize_decisions!(decisions, plan_id) when is_list(decisions) and decisions != [] do
    Enum.map(decisions, fn decision ->
      %{
        "schema_version" => "human_decision@1",
        "plan_id" => plan_id,
        "id" => fetch_required!(decision, :id),
        "title" => fetch_required!(decision, :title),
        "decision_type" => fetch_required!(decision, :decision_type),
        "improvement_refs" => normalize_string_list!(fetch_required!(decision, :improvement_refs))
      }
    end)
  end

  defp normalize_decisions!(_decisions, _plan_id) do
    raise ArgumentError, "planning graph requires at least one human decision"
  end

  defp normalize_epics!(epics, plan_id) when is_list(epics) and epics != [] do
    Enum.map(epics, fn epic ->
      %{
        "schema_version" => "epic@1",
        "plan_id" => plan_id,
        "id" => fetch_required!(epic, :id),
        "title" => fetch_required!(epic, :title),
        "requirement_refs" => normalize_string_list!(fetch_required!(epic, :requirement_refs))
      }
    end)
  end

  defp normalize_epics!(_epics, _plan_id) do
    raise ArgumentError, "planning graph requires at least one epic"
  end

  defp normalize_slices!(slices, plan_id) when is_list(slices) and slices != [] do
    Enum.map(slices, fn slice ->
      %{
        "schema_version" => "slice@1",
        "plan_id" => plan_id,
        "id" => fetch_required!(slice, :id),
        "epic_id" => fetch_required!(slice, :epic_id),
        "goal" => fetch_required!(slice, :goal),
        "current_behavior" => fetch_required!(slice, :current_behavior),
        "desired_behavior" => fetch_required!(slice, :desired_behavior),
        "requirement_refs" => normalize_string_list!(fetch_required!(slice, :requirement_refs)),
        "decision_refs" => normalize_string_list!(fetch_required!(slice, :decision_refs)),
        "improvement_refs" =>
          normalize_string_list!(fetch_required!(slice, :improvement_refs), allow_empty?: true),
        "likely_files" => normalize_string_list!(fetch_required!(slice, :likely_files)),
        "conflict_domains" => normalize_string_list!(fetch_required!(slice, :conflict_domains)),
        "autonomy_ceiling" => fetch_required!(slice, :autonomy_ceiling),
        "agent_brief_id" => fetch_required!(slice, :agent_brief_id),
        "agent_brief_version" => fetch_required!(slice, :agent_brief_version)
      }
    end)
  end

  defp normalize_slices!(_slices, _plan_id) do
    raise ArgumentError, "planning graph requires at least one slice"
  end

  defp normalize_agent_briefs!(briefs, plan_id) when is_list(briefs) and briefs != [] do
    Enum.map(briefs, &normalize_agent_brief!(&1, plan_id))
  end

  defp normalize_agent_briefs!(_briefs, _plan_id) do
    raise ArgumentError, "planning graph requires at least one AgentBrief"
  end

  defp normalize_agent_brief!(brief, plan_id) do
    brief_key = fetch_required!(brief, :id)

    %{
      "schema_version" => @brief_contract_version,
      "plan_id" => plan_id,
      "id" => brief_key,
      "brief_key" => brief_key,
      "title" => fetch_required!(brief, :title),
      "slice_id" => fetch_required!(brief, :slice_id),
      "version" => fetch_required!(brief, :version),
      "contract_version" =>
        Map.get(brief, :contract_version) ||
          Map.get(brief, "contract_version") ||
          @brief_contract_version,
      "locked" => Map.get(brief, :locked) || Map.get(brief, "locked") || false,
      "rerun_of" => Map.get(brief, :rerun_of) || Map.get(brief, "rerun_of")
    }
    |> put_optional_brief_field(brief, :current_behavior)
    |> put_optional_brief_field(brief, :desired_behavior)
    |> put_optional_brief_field(brief, :key_interfaces)
    |> put_optional_brief_field(brief, :acceptance_criteria_refs)
    |> put_optional_brief_field(brief, :required_tests)
    |> put_optional_brief_field(brief, :verification_commands)
    |> put_optional_brief_field(brief, :out_of_scope)
    |> put_optional_brief_field(brief, :risks)
    |> put_optional_brief_field(brief, :non_goals)
    |> put_optional_brief_field(brief, :allowed_write_paths)
    |> put_optional_brief_field(brief, :protected_paths)
    |> put_optional_brief_field(brief, :autonomy_level)
    |> put_optional_brief_field(brief, :lock_metadata)
    |> put_optional_brief_field(brief, :contract_digest)
  end

  defp create_record!(resource, external_id, name, payload) do
    attrs = %{external_id: external_id, name: name, status: "active", payload: payload}

    case Ash.create(resource, attrs, action: :create) do
      {:ok, record} ->
        record

      {:error, error} ->
        raise "failed to create #{inspect(resource)} #{external_id}: #{Exception.message(error)}"
    end
  end

  defp slice_traceability(slice) do
    %{
      slice_id: slice["id"],
      requirement_refs: slice["requirement_refs"],
      decision_refs: slice["decision_refs"],
      improvement_refs: slice["improvement_refs"],
      agent_brief_key: slice_agent_brief_key(slice)
    }
  end

  defp missing_requirement_findings(slice, requirement_keys) do
    slice["requirement_refs"]
    |> Enum.reject(&MapSet.member?(requirement_keys, &1))
    |> Enum.map(&finding("orphan_requirement_ref", slice, "requirement_refs", &1))
  end

  defp missing_decision_findings(slice, decision_ids) do
    slice["decision_refs"]
    |> Enum.reject(&MapSet.member?(decision_ids, &1))
    |> Enum.map(&finding("orphan_decision_ref", slice, "decision_refs", &1))
  end

  defp missing_improvement_findings(slice) do
    if slice["improvement_refs"] == [] do
      [finding("missing_improvement_ref", slice, "improvement_refs", nil)]
    else
      []
    end
  end

  defp missing_agent_brief_findings(slice, brief_keys) do
    brief_key = slice_agent_brief_key(slice)

    if MapSet.member?(brief_keys, brief_key) do
      []
    else
      [finding("orphan_agent_brief_ref", slice, "agent_brief_id", brief_key)]
    end
  end

  defp finding(code, slice, field, ref) do
    %{
      schema_version: @finding_schema_version,
      category: "planning_traceability",
      finding_code: code,
      severity: "error",
      slice_id: slice["id"],
      field: field,
      ref: ref,
      next_action:
        [
          "Update the plan so every Slice traces to existing requirement,",
          "decision, improvement, and AgentBrief refs."
        ]
        |> Enum.join(" ")
    }
  end

  defp agent_brief_key(brief), do: "#{brief["id"]}@#{brief["version"]}"

  defp slice_agent_brief_key(slice) do
    "#{slice["agent_brief_id"]}@#{slice["agent_brief_version"]}"
  end

  defp normalize_string_list!(values, opts \\ [])

  defp normalize_string_list!(values, opts) when is_list(values) do
    allow_empty? = Keyword.get(opts, :allow_empty?, false)

    if values != [] || allow_empty? do
      Enum.map(values, &to_string/1)
    else
      raise ArgumentError, "planning graph refs must be non-empty lists"
    end
  end

  defp normalize_string_list!(_values, _opts) do
    raise ArgumentError, "planning graph refs must be non-empty lists"
  end

  defp put_optional_brief_field(payload, source, key) do
    case Map.get(source, key, Map.get(source, to_string(key))) do
      nil -> payload
      value -> Map.put(payload, to_string(key), value)
    end
  end

  defp fetch_required!(map, key) do
    Map.get(map, key) ||
      Map.get(map, to_string(key)) ||
      raise ArgumentError, "missing planning graph field: #{key}"
  end
end
