defmodule Conveyor.PlanAudit do
  @moduledoc """
  Scores normalized `conveyor.plan@1` contracts for handoff readiness.

  `Conveyor.PlanImport` owns parsing and JSON-schema validation. This module
  adds deterministic control-plane checks for the dimensions that decide
  whether a plan is actionable for the tracer.
  """

  alias Conveyor.PlanImport

  @report_schema_version "conveyor.plan_audit.report@1"
  @finding_schema_version "conveyor.plan_audit.finding@1"
  @dimension_schema_version "conveyor.plan_audit.dimension_score@1"
  @next_action_schema_version "conveyor.plan_audit.next_action@1"
  @cutline "TRACER_REQUIRED"

  @dimension_weights [
    {"clarity", 10},
    {"acceptance_coverage", 15},
    {"testability", 15},
    {"requirement_traceability", 15},
    {"architecture_decisions", 12},
    {"autonomy_readiness", 12},
    {"risk_policy", 11},
    {"likely_files", 10}
  ]

  @autonomy_ranks %{"L0" => 0, "L1" => 1, "L2" => 2, "L3" => 3, "L4" => 4}

  def report_schema_version, do: @report_schema_version
  def finding_schema_version, do: @finding_schema_version

  def audit_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path
    |> PlanImport.lint_file(opts)
    |> audit_import_report(opts)
  end

  def audit_source(contents, source_path, opts \\ [])
      when is_binary(contents) and is_binary(source_path) and is_list(opts) do
    contents
    |> PlanImport.lint_source(source_path, opts)
    |> audit_import_report(opts)
  end

  def audit_import_report(%{} = import_report, _opts \\ []) do
    contract = Map.get(import_report, :normalized_contract)
    source_path = Map.get(import_report, :source_path, "conveyor.plan.json")
    source_refs = Map.get(import_report, :source_refs, [])
    import_findings = import_findings(import_report, source_path)
    {dimensions, audit_findings, score} = score_contract(contract, source_path)
    findings = import_findings ++ audit_findings
    handoff_ready = findings == [] and contract != nil

    %{
      schema_version: @report_schema_version,
      category: "plan_audit",
      status: if(handoff_ready, do: "handoff_ready", else: "blocked"),
      handoff_ready: handoff_ready,
      exit_code: if(handoff_ready, do: 0, else: 4),
      score: score,
      max_score: 100,
      cutline: @cutline,
      source_path: source_path,
      source_kind: Map.get(import_report, :source_kind),
      source_refs: source_refs,
      contract_schema_version: Map.get(import_report, :contract_schema_version),
      contract_sha256: Map.get(import_report, :contract_sha256),
      normalized_contract_summary: Map.get(import_report, :normalized_contract_summary),
      plan_import_status: Map.get(import_report, :status),
      dimensions: dimensions,
      findings: findings,
      next_actions: next_actions(findings),
      rerun_command: rerun_command(source_path)
    }
  end

  defp score_contract(nil, _source_path) do
    dimensions =
      Enum.map(@dimension_weights, fn {dimension, max_score} ->
        dimension_score(dimension, max_score, [])
      end)

    {dimensions, [], 0}
  end

  defp score_contract(contract, source_path) do
    results =
      Enum.map(@dimension_weights, fn {dimension, max_score} ->
        findings = dimension_findings(dimension, contract, source_path)
        dimension = dimension_score(dimension, max_score, findings)
        {dimension, findings}
      end)

    dimensions = Enum.map(results, &elem(&1, 0))
    findings = Enum.flat_map(results, &elem(&1, 1))
    score = Enum.reduce(dimensions, 0, &(&1.score + &2))

    {dimensions, findings, score}
  end

  defp dimension_score(dimension, max_score, findings) do
    blocked? = Enum.any?(findings, &(&1.severity == "blocking"))

    %{
      schema_version: @dimension_schema_version,
      dimension: dimension,
      status: if(blocked?, do: "blocked", else: "pass"),
      score: if(blocked?, do: 0, else: max_score),
      max_score: max_score,
      finding_codes: Enum.map(findings, & &1.finding_code)
    }
  end

  defp dimension_findings("clarity", contract, source_path) do
    goal = string_field(contract, "goal")
    project_key = get_in(contract, ["project", "key"])

    []
    |> maybe_finding(
      blank?(goal) or String.length(goal) < 24,
      "unclear_goal",
      "clarity",
      "$.goal",
      "plan goal must be a concrete, reviewable handoff target",
      "Rewrite the goal as the bounded outcome the tracer should make reviewable.",
      source_path
    )
    |> maybe_finding(
      blank?(project_key),
      "missing_project_key",
      "clarity",
      "$.project.key",
      "plan must name the target project key",
      "Set project.key to the project identifier used by the conductor.",
      source_path
    )
  end

  defp dimension_findings("acceptance_coverage", contract, source_path) do
    contract
    |> list_field("requirements")
    |> Enum.with_index()
    |> Enum.flat_map(fn {requirement, index} ->
      criteria = list_field(requirement, "acceptance_criteria")

      []
      |> maybe_finding(
        criteria == [],
        "missing_acceptance_criteria",
        "acceptance_coverage",
        "$.requirements[#{index}].acceptance_criteria",
        "each requirement must define at least one acceptance criterion",
        "Add acceptance_criteria entries that describe observable completion for this requirement.",
        source_path
      )
      |> maybe_finding(
        Enum.any?(criteria, &(blank?(Map.get(&1, "text")) or blank?(Map.get(&1, "ac_id")))),
        "incomplete_acceptance_criteria",
        "acceptance_coverage",
        "$.requirements[#{index}].acceptance_criteria",
        "acceptance criteria must include stable IDs and reviewable text",
        "Fill in ac_id and text for every acceptance criterion.",
        source_path
      )
    end)
  end

  defp dimension_findings("testability", contract, source_path) do
    commands = list_field(contract, "verification_commands")
    command_ids = ids(commands, "command_id")
    slices = list_field(contract, "slices")

    command_findings =
      []
      |> maybe_finding(
        commands == [],
        "missing_verification_commands",
        "testability",
        "$.verification_commands",
        "plan must include reproducible verification commands",
        "Add verification_commands with stable command_id values and argv arrays.",
        source_path
      )

    empty_command_findings =
      commands
      |> Enum.with_index()
      |> Enum.flat_map(fn {command, index} ->
        []
        |> maybe_finding(
          list_field(command, "command") == [],
          "empty_verification_command",
          "testability",
          "$.verification_commands[#{index}].command",
          "verification command must include at least one argv token",
          "Populate the command array with the exact command the operator can rerun.",
          source_path
        )
      end)

    slice_findings =
      slices
      |> Enum.with_index()
      |> Enum.flat_map(fn {slice, index} ->
        refs = list_field(slice, "verification_refs")

        []
        |> maybe_finding(
          refs == [],
          "missing_slice_verification",
          "testability",
          "$.slices[#{index}].verification_refs",
          "each slice must reference at least one verification command",
          "Add verification_refs that point to command_id values in verification_commands.",
          source_path
        )
        |> Kernel.++(
          unknown_ref_findings(
            refs,
            command_ids,
            "unknown_verification_ref",
            "testability",
            "$.slices[#{index}].verification_refs",
            "slice references a verification command that is not declared",
            "Declare the command_id in verification_commands or update the verification_refs entry.",
            source_path
          )
        )
      end)

    command_findings ++ empty_command_findings ++ slice_findings
  end

  defp dimension_findings("requirement_traceability", contract, source_path) do
    requirements = list_field(contract, "requirements")
    requirement_ids = ids(requirements, "requirement_id")
    slices = list_field(contract, "slices")

    slice_findings =
      slices
      |> Enum.with_index()
      |> Enum.flat_map(fn {slice, index} ->
        refs = list_field(slice, "requirement_refs")

        []
        |> maybe_finding(
          refs == [],
          "missing_requirement_refs",
          "requirement_traceability",
          "$.slices[#{index}].requirement_refs",
          "each slice must reference at least one requirement",
          "Add requirement_refs that point to requirement_id values.",
          source_path
        )
        |> Kernel.++(
          unknown_ref_findings(
            refs,
            requirement_ids,
            "unknown_requirement_ref",
            "requirement_traceability",
            "$.slices[#{index}].requirement_refs",
            "slice references a requirement that is not declared",
            "Declare the requirement_id or update the slice requirement_refs entry.",
            source_path
          )
        )
      end)

    covered_requirement_ids =
      slices
      |> Enum.flat_map(&list_field(&1, "requirement_refs"))
      |> MapSet.new()

    uncovered_findings =
      requirements
      |> Enum.with_index()
      |> Enum.flat_map(fn {requirement, index} ->
        requirement_id = Map.get(requirement, "requirement_id")

        []
        |> maybe_finding(
          not blank?(requirement_id) and
            not MapSet.member?(covered_requirement_ids, requirement_id),
          "uncovered_requirement",
          "requirement_traceability",
          "$.requirements[#{index}].requirement_id",
          "requirement is not covered by any slice",
          "Add the requirement_id to at least one slice requirement_refs list.",
          source_path
        )
      end)

    slice_findings ++ uncovered_findings
  end

  defp dimension_findings("architecture_decisions", contract, source_path) do
    decisions = list_field(contract, "decisions")
    decision_ids = ids(decisions, "decision_id")
    slices = list_field(contract, "slices")

    decision_findings =
      []
      |> maybe_finding(
        decisions == [],
        "missing_architecture_decisions",
        "architecture_decisions",
        "$.decisions",
        "plan must capture the architecture decisions that constrain implementation",
        "Add decisions with stable decision_id values, titles, and rationales.",
        source_path
      )

    incomplete_decision_findings =
      decisions
      |> Enum.with_index()
      |> Enum.flat_map(fn {decision, index} ->
        []
        |> maybe_finding(
          blank?(Map.get(decision, "rationale")),
          "missing_decision_rationale",
          "architecture_decisions",
          "$.decisions[#{index}].rationale",
          "architecture decisions must include rationale",
          "Add rationale that explains why this decision constrains the plan.",
          source_path
        )
      end)

    slice_findings =
      slices
      |> Enum.with_index()
      |> Enum.flat_map(fn {slice, index} ->
        refs = list_field(slice, "decision_refs")

        []
        |> maybe_finding(
          refs == [],
          "missing_slice_decision_refs",
          "architecture_decisions",
          "$.slices[#{index}].decision_refs",
          "each slice must reference the decisions that shape it",
          "Add decision_refs that point to decision_id values.",
          source_path
        )
        |> Kernel.++(
          unknown_ref_findings(
            refs,
            decision_ids,
            "unknown_decision_ref",
            "architecture_decisions",
            "$.slices[#{index}].decision_refs",
            "slice references a decision that is not declared",
            "Declare the decision_id or update the slice decision_refs entry.",
            source_path
          )
        )
      end)

    decision_findings ++ incomplete_decision_findings ++ slice_findings
  end

  defp dimension_findings("autonomy_readiness", contract, source_path) do
    plan_level = string_field(contract, "autonomy_level")
    plan_rank = Map.get(@autonomy_ranks, plan_level)

    plan_findings =
      []
      |> maybe_finding(
        plan_level != "L1",
        "unsupported_plan_autonomy",
        "autonomy_readiness",
        "$.autonomy_level",
        "Phase 1 handoff-ready plans must stay at autonomy level L1",
        "Set autonomy_level to L1 or split work until the plan is operator-assisted.",
        source_path
      )

    slice_findings =
      contract
      |> list_field("slices")
      |> Enum.with_index()
      |> Enum.flat_map(fn {slice, index} ->
        slice_level = string_field(slice, "autonomy_level")
        slice_rank = Map.get(@autonomy_ranks, slice_level)

        []
        |> maybe_finding(
          slice_rank == nil,
          "unknown_slice_autonomy",
          "autonomy_readiness",
          "$.slices[#{index}].autonomy_level",
          "slice autonomy level must be one of L0 through L4",
          "Set the slice autonomy_level to a supported L0-L4 value.",
          source_path
        )
        |> maybe_finding(
          plan_rank != nil and slice_rank != nil and slice_rank > plan_rank,
          "slice_autonomy_exceeds_plan",
          "autonomy_readiness",
          "$.slices[#{index}].autonomy_level",
          "slice autonomy may not exceed the plan autonomy level",
          "Lower the slice autonomy_level or raise and rejustify the plan autonomy_level.",
          source_path
        )
      end)

    plan_findings ++ slice_findings
  end

  defp dimension_findings("risk_policy", contract, source_path) do
    cutline = string_field(contract, "cutline")

    cutline_findings =
      []
      |> maybe_finding(
        cutline != @cutline,
        "missing_risk_policy",
        "risk_policy",
        "$.cutline",
        "plan must declare the TRACER_REQUIRED cutline risk policy",
        "Set cutline to TRACER_REQUIRED before handoff.",
        source_path
      )

    conflict_findings =
      contract
      |> list_field("slices")
      |> Enum.with_index()
      |> Enum.flat_map(fn {slice, index} ->
        []
        |> maybe_finding(
          list_field(slice, "conflict_domains") == [],
          "missing_conflict_domains",
          "risk_policy",
          "$.slices[#{index}].conflict_domains",
          "each slice must declare conflict domains for coordination and risk review",
          "Add conflict_domains that name the shared surfaces this slice may touch.",
          source_path
        )
      end)

    cutline_findings ++ conflict_findings
  end

  defp dimension_findings("likely_files", contract, source_path) do
    contract
    |> list_field("slices")
    |> Enum.with_index()
    |> Enum.flat_map(fn {slice, index} ->
      []
      |> maybe_finding(
        list_field(slice, "likely_files") == [],
        "missing_likely_files",
        "likely_files",
        "$.slices[#{index}].likely_files",
        "each slice must name the likely files or globs it expects to edit",
        "Add likely_files entries so agents can reserve and coordinate the edit surface.",
        source_path
      )
    end)
  end

  defp unknown_ref_findings(
         refs,
         known_ids,
         code,
         dimension,
         path,
         message,
         action,
         source_path
       ) do
    refs
    |> Enum.reject(&MapSet.member?(known_ids, &1))
    |> Enum.map(fn ref ->
      finding(
        code,
        dimension,
        path,
        "#{message}: #{ref}",
        action,
        source_path,
        %{ref: ref}
      )
    end)
  end

  defp import_findings(import_report, source_path) do
    import_report
    |> Map.get(:findings, [])
    |> Enum.filter(&(Map.get(&1, :severity) == "error"))
    |> Enum.map(fn finding ->
      source_code = Map.get(finding, :finding_code)

      finding(
        "invalid_plan_contract",
        "plan_import",
        Map.get(finding, :path, "$"),
        "plan import reported #{source_code}: #{Map.get(finding, :message)}",
        "Fix the normalized conveyor.plan@1 contract so schema validation passes.",
        source_path,
        %{source_finding_code: source_code}
      )
    end)
  end

  defp maybe_finding(findings, false, _code, _dimension, _path, _message, _action, _source_path),
    do: findings

  defp maybe_finding(findings, true, code, dimension, path, message, action, source_path),
    do: findings ++ [finding(code, dimension, path, message, action, source_path)]

  defp finding(code, dimension, path, message, action, source_path, extra \\ %{}) do
    %{
      schema_version: @finding_schema_version,
      category: "plan_audit",
      finding_code: code,
      severity: "blocking",
      dimension: dimension,
      path: path,
      message: message,
      next_actions: [
        %{
          schema_version: @next_action_schema_version,
          label: action,
          command: rerun_command(source_path)
        }
      ],
      rerun_command: rerun_command(source_path)
    }
    |> Map.merge(extra)
  end

  defp next_actions(findings) do
    findings
    |> Enum.flat_map(& &1.next_actions)
    |> Enum.uniq_by(fn action -> {action.label, action.command} end)
  end

  defp rerun_command(source_path), do: ["mix", "conveyor.plan_audit", source_path]

  defp ids(values, key) do
    values
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
  end

  defp list_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp list_field(_other, _key), do: []

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp string_field(_other, _key), do: ""

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
