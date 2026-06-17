defmodule Conveyor.Artifacts.Dossier do
  @moduledoc """
  Renders human-readable report artifacts from conductor-owned machine evidence.

  The renderer only consumes recorded evidence payloads. Agent self-report text is
  not part of the evidence schema and is therefore never used here.
  """

  @summary_schema_version "conveyor.human_report_generation_summary@1"
  @finding_schema_version "conveyor.human_report_generation_finding@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"

  @required_sections [
    {:task_context, "task_context"},
    {:requirement_traceability, "requirement_traceability"},
    {:summary, "summary"},
    {:diff, "diff"},
    {:acceptance_mapping, "acceptance_mapping"},
    {:conductor_commands, "conductor_commands"},
    {:quality_delta, "quality_delta"},
    {:reviewer_verdict, "reviewer_verdict"},
    {:gate_result, "gate_result"},
    {:policy_safety, "policy_safety"},
    {:known_risks, "known_risks"},
    {:bundle_digests, "bundle_digests"}
  ]

  def render(evidence, opts \\ []) when is_map(evidence) and is_list(opts) do
    case missing_sections(evidence) do
      [] ->
        context = report_context(evidence, opts)
        dossier_md = render_dossier(evidence, context)
        pr_body_md = render_pr_body(evidence, context)

        {:ok,
         %{
           dossier_md: dossier_md,
           pr_body_md: pr_body_md,
           summary: generation_summary(evidence, dossier_md, pr_body_md)
         }}

      missing_sections ->
        {:error, missing_section_finding(evidence, missing_sections)}
    end
  end

  def missing_section_finding(evidence, missing_sections) when is_map(evidence) do
    %{
      schema_version: @finding_schema_version,
      category: "human_report_missing_section",
      failure_category: "missing_human_report_section",
      severity: "error",
      matrix_ref: @matrix_ref,
      evidence_id: Map.get(evidence, "evidence_id"),
      run_id: Map.get(evidence, "run_id"),
      missing_sections: missing_sections,
      required_sections: Enum.map(@required_sections, &elem(&1, 1)),
      action: "block_report_projection",
      message:
        "Recorded evidence is missing sections required to generate dossier.md and pr_body.md."
    }
  end

  defp render_dossier(evidence, context) do
    [
      "# Conveyor Human Dossier",
      task_context_section(evidence, context),
      requirement_traceability_section(evidence),
      summary_section(evidence),
      diff_section(evidence),
      acceptance_mapping_section(evidence),
      conductor_commands_section(evidence),
      quality_delta_section(evidence),
      reviewer_verdict_section(evidence),
      gate_result_section(evidence),
      policy_safety_section(evidence),
      known_risks_section(evidence),
      bundle_digests_section(evidence, context)
    ]
    |> Enum.join("\n\n")
    |> then(&(&1 <> "\n"))
  end

  defp render_pr_body(evidence, context) do
    [
      "## Task",
      task_summary(evidence, context),
      "## Summary",
      value(evidence, "summary"),
      "## Acceptance Criteria",
      acceptance_checkboxes(evidence),
      "## Verification",
      verification_lines(evidence),
      "## Risk",
      risk_lines(evidence),
      "## Agent/Profile",
      agent_profile_lines(evidence),
      "## Evidence Digests",
      evidence_digest_lines(evidence, context)
    ]
    |> Enum.join("\n\n")
    |> then(&(&1 <> "\n"))
  end

  defp task_context_section(evidence, context) do
    """
    ## Task Context
    - Run: #{context.run_id}
    - Bundle: #{context.bundle_id}
    - Slice: #{value(evidence, "slice_id")}
    - Evidence: #{value(evidence, "evidence_id")}
    - Autonomy: #{value(evidence, "autonomy_level")}
    - Agent: #{agent_profile_inline(evidence)}
    """
    |> String.trim()
  end

  defp requirement_traceability_section(evidence) do
    """
    ## Requirement Traceability
    #{criteria_lines(evidence)}
    """
    |> String.trim()
  end

  defp summary_section(evidence) do
    """
    ## Summary
    #{value(evidence, "summary")}
    """
    |> String.trim()
  end

  defp diff_section(evidence) do
    changed_files = list_value(evidence, "changed_files")

    """
    ## Diff
    - Base commit: #{value(evidence, "base_commit")}
    - Head commit: #{value(evidence, "head_commit")}
    - Diff ref: #{value(evidence, "diff_ref")}
    - Changed files: #{inline_list(changed_files)}
    """
    |> String.trim()
  end

  defp acceptance_mapping_section(evidence) do
    """
    ## AC-to-Evidence Mapping
    #{acceptance_mapping_lines(evidence)}
    """
    |> String.trim()
  end

  defp conductor_commands_section(evidence) do
    """
    ## Conductor Commands
    #{command_lines(evidence)}
    """
    |> String.trim()
  end

  defp quality_delta_section(evidence) do
    """
    ## Quality Delta
    #{quality_lines(evidence)}
    """
    |> String.trim()
  end

  defp reviewer_verdict_section(evidence) do
    """
    ## Reviewer Verdict
    #{result_lines(map_value(evidence, "review_result"))}
    """
    |> String.trim()
  end

  defp gate_result_section(evidence) do
    """
    ## Gate Result
    #{result_lines(map_value(evidence, "gate_result"))}
    """
    |> String.trim()
  end

  defp policy_safety_section(evidence) do
    violations = list_value(evidence, "policy_violations")

    body =
      case violations do
        [] ->
          "- Redaction status: #{value(evidence, "redaction_status")}\n- No policy violations recorded."

        _ ->
          Enum.map_join(violations, "\n", &("- " <> compact_map(&1)))
      end

    """
    ## Policy and Safety
    #{body}
    """
    |> String.trim()
  end

  defp known_risks_section(evidence) do
    """
    ## Known Risks
    #{risk_lines(evidence)}
    """
    |> String.trim()
  end

  defp bundle_digests_section(evidence, context) do
    """
    ## Bundle Digests
    #{evidence_digest_lines(evidence, context)}
    """
    |> String.trim()
  end

  defp task_summary(evidence, context) do
    "- Run #{context.run_id}, slice #{value(evidence, "slice_id")}, bundle #{context.bundle_id}."
  end

  defp criteria_lines(evidence) do
    evidence
    |> acceptance_criteria()
    |> Enum.map_join("\n", fn criterion ->
      "- #{criterion["criterion_id"]}: #{criterion["description"]}"
    end)
  end

  defp acceptance_mapping_lines(evidence) do
    results_by_id = results_by_id(evidence)

    evidence
    |> acceptance_criteria()
    |> Enum.map_join("\n", fn criterion ->
      criterion_id = criterion["criterion_id"]
      description = criterion["description"]
      result = Map.fetch!(results_by_id, criterion_id)
      status = result["status"]

      evidence_refs = inline_list(result["evidence_refs"] || [])

      "- #{criterion_id}: #{description} | status=#{status} | evidence=#{evidence_refs}"
    end)
  end

  defp acceptance_checkboxes(evidence) do
    results_by_id = results_by_id(evidence)

    evidence
    |> acceptance_criteria()
    |> Enum.map_join("\n", fn criterion ->
      criterion_id = criterion["criterion_id"]
      description = criterion["description"]
      result = Map.fetch!(results_by_id, criterion_id)
      status = result["status"]
      checkbox = if status in ["pass", "passed"], do: "x", else: " "

      evidence_refs = inline_list(result["evidence_refs"] || [])

      "- [#{checkbox}] #{criterion_id}: #{description} (#{status}; evidence: #{evidence_refs})"
    end)
  end

  defp command_lines(evidence) do
    evidence
    |> list_value("conductor_commands")
    |> Enum.map_join("\n", fn command ->
      command_id = command["command_id"]
      command_text = command["command"]
      status = command["status"]
      exit_code = command["exit_code"]
      evidence_ref = command["evidence_ref"]

      "- #{command_id}: `#{command_text}` -> #{status} (exit #{exit_code}; #{evidence_ref})"
    end)
  end

  defp verification_lines(evidence) do
    command_lines(evidence)
  end

  defp quality_lines(evidence) do
    case list_value(evidence, "quality_refs") do
      [] -> "- No quality refs recorded."
      refs -> Enum.map_join(refs, "\n", &("- " <> &1))
    end
  end

  defp risk_lines(evidence) do
    case list_value(evidence, "known_risks") do
      [] -> "- No known risks recorded."
      risks -> Enum.map_join(risks, "\n", &("- " <> compact_map(&1)))
    end
  end

  defp agent_profile_lines(evidence) do
    agent = map_value(evidence, "agent")

    """
    - Adapter: #{value(agent, "adapter")}
    - Session: #{value(agent, "session_id")}
    - Profile: #{value(agent, "profile_id")}
    """
    |> String.trim()
  end

  defp agent_profile_inline(evidence) do
    agent = map_value(evidence, "agent")
    adapter = value(agent, "adapter")
    profile_id = value(agent, "profile_id")
    session_id = value(agent, "session_id")

    "#{adapter} / #{profile_id} / #{session_id}"
  end

  defp evidence_digest_lines(evidence, context) do
    """
    - Evidence SHA-256: #{value(evidence, "sha256")}
    - Evidence path: #{value(evidence, "path")}
    - Manifest: .conveyor/runs/#{context.run_id}/manifest.json
    - Run bundle: .conveyor/runs/#{context.run_id}/run_bundle.json
    - Final bundle_root_sha256: recorded in run_bundle.json after projection
    """
    |> String.trim()
  end

  defp result_lines(result) do
    case result do
      %{} ->
        decision = value(result, "decision", value(result, "status", "unknown"))
        refs = list_value(result, "evidence_refs")
        rest = result |> Map.drop(["decision", "status", "evidence_refs"]) |> compact_map()

        [
          "- Decision: #{decision}",
          "- Evidence refs: #{inline_list(refs)}",
          "- Details: #{rest}"
        ]
        |> Enum.join("\n")

      _ ->
        "- Not recorded."
    end
  end

  defp generation_summary(evidence, dossier_md, pr_body_md) do
    %{
      schema_version: @summary_schema_version,
      category: "human_report_generation",
      matrix_ref: @matrix_ref,
      evidence_id: Map.get(evidence, "evidence_id"),
      run_id: Map.get(evidence, "run_id"),
      slice_id: Map.get(evidence, "slice_id"),
      generated_sections: Enum.map(@required_sections, &elem(&1, 1)),
      dossier_bytes: byte_size(dossier_md),
      pr_body_bytes: byte_size(pr_body_md),
      finding_count: 0
    }
  end

  defp report_context(evidence, opts) do
    %{
      run_id: Keyword.get(opts, :run_id, Map.get(evidence, "run_id")),
      bundle_id: Keyword.get(opts, :bundle_id, "unknown-bundle")
    }
  end

  defp missing_sections(evidence) do
    Enum.flat_map(@required_sections, fn {section, section_name} ->
      if section_present?(section, evidence), do: [], else: [section_name]
    end)
  end

  defp section_present?(:task_context, evidence) do
    present?(evidence["run_id"]) and present?(evidence["slice_id"]) and
      present?(evidence["agent"])
  end

  defp section_present?(:requirement_traceability, evidence),
    do: acceptance_criteria(evidence) != []

  defp section_present?(:summary, evidence), do: present?(evidence["summary"])

  defp section_present?(:diff, evidence) do
    present?(evidence["base_commit"]) and present?(evidence["head_commit"]) and
      present?(evidence["diff_ref"]) and list_value(evidence, "changed_files") != []
  end

  defp section_present?(:acceptance_mapping, evidence) do
    criteria = acceptance_criteria(evidence)
    results = results_by_id(evidence)

    criteria != [] and
      Enum.all?(criteria, fn criterion ->
        result = Map.get(results, criterion["criterion_id"])
        is_map(result) and list_value(result, "evidence_refs") != []
      end)
  end

  defp section_present?(:conductor_commands, evidence),
    do: list_value(evidence, "conductor_commands") != []

  defp section_present?(:quality_delta, evidence), do: Map.has_key?(evidence, "quality_refs")
  defp section_present?(:reviewer_verdict, evidence), do: is_map(evidence["review_result"])
  defp section_present?(:gate_result, evidence), do: is_map(evidence["gate_result"])

  defp section_present?(:policy_safety, evidence) do
    Map.has_key?(evidence, "policy_violations") and Map.has_key?(evidence, "redaction_status")
  end

  defp section_present?(:known_risks, evidence), do: Map.has_key?(evidence, "known_risks")
  defp section_present?(:bundle_digests, evidence), do: present?(evidence["sha256"])

  defp acceptance_criteria(evidence), do: get_in(evidence, ["acceptance", "criteria"]) || []
  defp acceptance_results(evidence), do: get_in(evidence, ["acceptance", "results"]) || []

  defp results_by_id(evidence) do
    Map.new(acceptance_results(evidence), fn result -> {result["criterion_id"], result} end)
  end

  defp list_value(map, key) when is_map(map) do
    case Map.get(map, key, []) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp value(map, key, default \\ "not recorded")
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, default) || default
  defp value(_map, _key, default), do: default

  defp compact_map(map) when is_map(map) and map == %{}, do: "none"

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{compact_value(value)}" end)
  end

  defp compact_map(value), do: compact_value(value)

  defp compact_value(value) when is_list(value), do: inline_list(value)
  defp compact_value(value) when is_map(value), do: "{" <> compact_map(value) <> "}"
  defp compact_value(value), do: to_string(value)

  defp inline_list([]), do: "none"
  defp inline_list(values), do: Enum.map_join(values, ", ", &compact_value/1)

  defp present?(value), do: value not in [nil, "", []]
end
