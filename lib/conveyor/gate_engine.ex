defmodule Conveyor.GateEngine do
  @moduledoc """
  Deterministic Gate stage composition.

  The engine owns the mechanical verdict and returns transition plans for the
  existing RunAttempt and Slice state machines. Callers still execute those
  transitions through the domain resources.
  """

  alias Conveyor.Domain.GateResult
  alias Conveyor.Domain.PayloadHelpers
  alias Conveyor.Domain.RunAttempt
  alias Conveyor.Domain.Slice

  @schema_version "conveyor.gate_engine@1"
  @stage_log_schema_version "conveyor.gate_stage_log@1"
  @finding_schema_version "conveyor.gate_failure_finding@1"
  @summary_schema_version "conveyor.gate_result_summary@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @harness_ref "conveyor-quality-ci-evals-vmr.14"
  @pass_statuses MapSet.new(["pass", "passed", "ok", "success"])
  @test_execution_stage_keys MapSet.new([
                               "acceptance",
                               "acceptance_mapping",
                               "acceptance_tests",
                               "gate_tests",
                               "test_execution",
                               "tests"
                             ])

  def compose!(attrs) when is_map(attrs) do
    evaluated_at =
      attrs
      |> PayloadHelpers.get(:evaluated_at, DateTime.utc_now())
      |> PayloadHelpers.iso8601()

    stage_results =
      attrs
      |> PayloadHelpers.fetch_required!(:stages)
      |> Enum.map(&normalize_stage!/1)
      |> Enum.sort_by(& &1["stage_key"])

    failed_required_stages = Enum.filter(stage_results, &required_failure?/1)
    decision = if failed_required_stages == [], do: "pass", else: "fail"
    failure_findings = Enum.map(failed_required_stages, &failure_finding/1)
    stage_log = Enum.map(stage_results, &stage_log_entry(&1, evaluated_at))
    transition_plan = transition_plan(decision, attrs, failure_findings)

    gate_result =
      attrs
      |> gate_result_attrs(decision, stage_results, stage_log, failure_findings, transition_plan)
      |> GateResult.build!()

    %{
      schema_version: @schema_version,
      category: "deterministic_gate_composition",
      decision: decision,
      required_stage_count: Enum.count(stage_results, & &1["required"]),
      failed_required_stage_count: length(failed_required_stages),
      gate_result: gate_result,
      stage_log: stage_log,
      failure_findings: failure_findings,
      transition_plan: transition_plan,
      summary: summary(gate_result)
    }
  end

  def summary(gate_result) when is_map(gate_result) do
    %{
      schema_version: @summary_schema_version,
      category: "gate_result_composition",
      gate_result_id: gate_result["gate_result_id"],
      decision: gate_result["decision"],
      gate_version: gate_result["gate_version"],
      gate_code_digest: gate_result["gate_code_digest"],
      policy_digest: gate_result["policy_digest"],
      contract_lock_digest: gate_result["contract_lock_digest"],
      canary_suite_version: gate_result["canary_suite_version"],
      stage_count: length(gate_result["stage_results"] || []),
      failure_count: length(gate_result["failure_findings"] || []),
      matrix_ref: @matrix_ref,
      harness_ref: @harness_ref
    }
  end

  def apply_transitions(composition, run_attempt, slice, opts \\ [])

  def apply_transitions(
        %{decision: "pass", transition_plan: transition_plan},
        run_attempt,
        slice,
        opts
      ) do
    context = get_in(transition_plan, ["run_attempt", "context"]) || %{}

    with {:ok, gated_attempt, attempt_event, attempt_outbox, attempt_log} <-
           RunAttempt.transition(run_attempt, :gate, context, opts),
         {:ok, gated_slice, slice_event, slice_outbox, slice_log} <-
           Slice.transition(slice, :gate, context, opts) do
      {:ok,
       %{
         run_attempt: gated_attempt,
         slice: gated_slice,
         ledger_events: [attempt_event, slice_event],
         outbox_entries: attempt_outbox ++ slice_outbox,
         transition_logs: [attempt_log, slice_log]
       }}
    end
  end

  def apply_transitions(%{decision: "fail"} = composition, _run_attempt, _slice, _opts) do
    {:error,
     %{
       schema_version: @finding_schema_version,
       category: "gate_transition_blocked",
       severity: "blocking",
       matrix_ref: @matrix_ref,
       harness_ref: @harness_ref,
       failed_required_stages:
         get_in(composition, [:transition_plan, "run_attempt", "blocked_by"]) || [],
       action: "keep_run_attempt_and_slice_ungated",
       message: "Gate transitions are only allowed after all required stages pass."
     }}
  end

  defp gate_result_attrs(
         attrs,
         decision,
         stage_results,
         stage_log,
         failure_findings,
         transition_plan
       ) do
    %{
      gate_result_id: PayloadHelpers.fetch_required!(attrs, :gate_result_id),
      run_attempt_id: PayloadHelpers.fetch_required!(attrs, :run_attempt_id),
      station_run_id: PayloadHelpers.fetch_required!(attrs, :station_run_id),
      decision: decision,
      suite_kind: PayloadHelpers.get(attrs, :suite_kind, "gate"),
      gate_version: PayloadHelpers.fetch_required!(attrs, :gate_version),
      gate_code_digest: PayloadHelpers.fetch_required!(attrs, :gate_code_digest),
      policy_digest: PayloadHelpers.fetch_required!(attrs, :policy_digest),
      contract_lock_digest: PayloadHelpers.fetch_required!(attrs, :contract_lock_digest),
      canary_suite_version: PayloadHelpers.fetch_required!(attrs, :canary_suite_version),
      evidence_refs: PayloadHelpers.get(attrs, :evidence_refs, []),
      finding_refs: Enum.map(failure_findings, & &1["finding_ref"]),
      stage_results: stage_results,
      stage_log: stage_log,
      failure_findings: failure_findings,
      transition_plan: transition_plan,
      metadata:
        attrs
        |> PayloadHelpers.get(:metadata, %{})
        |> PayloadHelpers.normalize_map()
        |> Map.merge(%{
          "matrix_ref" => @matrix_ref,
          "harness_ref" => @harness_ref
        })
    }
    |> put_if_present(:review_id, PayloadHelpers.get(attrs, :review_id))
  end

  defp normalize_stage!(stage) when is_map(stage) do
    stage_key = stage |> PayloadHelpers.fetch_required!(:stage_key) |> to_string()

    status =
      normalize_status(PayloadHelpers.get(stage, :status, PayloadHelpers.get(stage, :decision)))

    required = PayloadHelpers.get(stage, :required, true) != false

    details =
      stage
      |> PayloadHelpers.get(:details, PayloadHelpers.get(stage, :metadata, %{}))
      |> PayloadHelpers.normalize_map()

    findings = stage_findings(stage_key, details)
    passed = passed?(status) and blocking_findings(findings) == []

    %{
      "schema_version" => "conveyor.gate_stage_result@1",
      "stage_key" => stage_key,
      "required" => required,
      "status" => status,
      "passed" => passed,
      "next_action" => next_action(stage, stage_key, required, status, findings),
      "details" => details,
      "findings" => findings
    }
  end

  defp normalize_stage!(_stage), do: raise(ArgumentError, "gate stages must be maps")

  defp normalize_status(nil), do: raise(ArgumentError, "gate stage is missing status")

  defp normalize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> normalize_status()

  defp normalize_status(true), do: "pass"
  defp normalize_status(false), do: "fail"
  defp normalize_status(status) when is_binary(status), do: String.downcase(status)

  defp normalize_status(status) do
    raise ArgumentError, "unsupported gate stage status: #{inspect(status)}"
  end

  defp detail_status(nil), do: nil
  defp detail_status(status), do: normalize_status(status)

  defp required_failure?(%{"required" => true, "passed" => false}), do: true
  defp required_failure?(_stage), do: false

  defp passed?(status), do: MapSet.member?(@pass_statuses, status)

  defp next_action(stage, stage_key, true, status, findings) do
    PayloadHelpers.get(stage, :next_action) ||
      cond do
        blocking_findings(findings) != [] -> "resolve_#{stage_key}_evidence_before_gate"
        passed?(status) -> nil
        true -> "resolve_#{stage_key}_before_gate"
      end
  end

  defp next_action(stage, _stage_key, false, _status, _findings),
    do: PayloadHelpers.get(stage, :next_action)

  defp failure_finding(stage) do
    detail_findings = blocking_findings(stage["findings"] || [])

    %{
      "schema_version" => @finding_schema_version,
      "category" => "required_gate_stage_failed",
      "severity" => "blocking",
      "matrix_ref" => @matrix_ref,
      "harness_ref" => @harness_ref,
      "finding_ref" => "gate-required-stage-failed:#{stage["stage_key"]}",
      "stage_key" => stage["stage_key"],
      "stage_status" => stage["status"],
      "failure_categories" => Enum.map(detail_findings, & &1["failure_category"]),
      "detail_findings" => detail_findings,
      "next_action" => stage["next_action"],
      "action" => "block_gate",
      "message" => "Required gate stage #{stage["stage_key"]} did not pass."
    }
  end

  defp stage_log_entry(stage, evaluated_at) do
    %{
      "schema_version" => @stage_log_schema_version,
      "stage_key" => stage["stage_key"],
      "required" => stage["required"],
      "status" => stage["status"],
      "passed" => stage["passed"],
      "logged_at" => evaluated_at,
      "next_action" => stage["next_action"],
      "details" => stage["details"],
      "findings" => stage["findings"]
    }
  end

  defp stage_findings(stage_key, details) do
    if test_execution_stage?(stage_key, details) do
      findings =
        baseline_findings(details) ++
          locked_acceptance_findings(details) ++
          retry_findings(details) ++
          acceptance_mapping_findings(details)

      Enum.reject(findings, &is_nil/1)
    else
      []
    end
  end

  defp test_execution_stage?(stage_key, details) do
    MapSet.member?(@test_execution_stage_keys, stage_key) or
      Map.has_key?(details, "baseline") or
      Map.has_key?(details, "locked_acceptance") or
      Map.has_key?(details, "acceptance_results")
  end

  defp baseline_findings(details) do
    case Map.get(details, "baseline") do
      nil ->
        [stage_finding("missing_baseline_result", "Baseline regression result is required.")]

      baseline when is_map(baseline) ->
        [
          unless passed?(detail_status(Map.get(baseline, "status"))) do
            stage_finding("baseline_regression_failed", "Baseline regression suite did not pass.")
          end,
          unless evidence_refs_present?(baseline) do
            stage_finding(
              "missing_baseline_evidence",
              "Baseline regression suite is missing evidence refs."
            )
          end
        ]

      _baseline ->
        [stage_finding("invalid_baseline_result", "Baseline regression result must be a map.")]
    end
  end

  defp locked_acceptance_findings(details) do
    locked_acceptance = Map.get(details, "locked_acceptance") || Map.get(details, "acceptance")

    case locked_acceptance do
      nil ->
        [
          stage_finding(
            "missing_locked_acceptance_result",
            "Locked acceptance result is required."
          )
        ]

      locked when is_map(locked) ->
        calibration = Map.get(locked, "base_calibration") || Map.get(locked, "calibration")
        patch_result = Map.get(locked, "patch_result") || Map.get(locked, "patched") || locked

        calibration_findings(calibration) ++ patch_acceptance_findings(patch_result)

      _locked ->
        [
          stage_finding(
            "invalid_locked_acceptance_result",
            "Locked acceptance result must be a map."
          )
        ]
    end
  end

  defp calibration_findings(nil) do
    [
      stage_finding(
        "missing_acceptance_calibration",
        "Locked acceptance suite must record red calibration on the base revision."
      )
    ]
  end

  defp calibration_findings(calibration) when is_map(calibration) do
    [
      if passed?(detail_status(Map.get(calibration, "status"))) do
        stage_finding(
          "acceptance_not_calibrated_red",
          "Locked acceptance suite must fail on the base revision before patch verification."
        )
      end,
      unless evidence_refs_present?(calibration) do
        stage_finding(
          "missing_acceptance_calibration_evidence",
          "Locked acceptance calibration is missing evidence refs."
        )
      end
    ]
  end

  defp calibration_findings(_calibration) do
    [stage_finding("invalid_acceptance_calibration", "Acceptance calibration must be a map.")]
  end

  defp patch_acceptance_findings(patch_result) when is_map(patch_result) do
    [
      unless passed?(detail_status(Map.get(patch_result, "status"))) do
        stage_finding(
          "locked_acceptance_failed",
          "Locked acceptance suite did not pass after patch."
        )
      end,
      unless evidence_refs_present?(patch_result) do
        stage_finding(
          "missing_locked_acceptance_evidence",
          "Locked acceptance patch result is missing evidence refs."
        )
      end
    ]
  end

  defp patch_acceptance_findings(_patch_result) do
    [
      stage_finding(
        "invalid_locked_acceptance_patch_result",
        "Acceptance patch result must be a map."
      )
    ]
  end

  defp retry_findings(details) do
    attempts =
      details
      |> Map.get("attempts", [])
      |> normalize_attempts()

    locked_attempts =
      case Map.get(details, "locked_acceptance", %{}) do
        locked when is_map(locked) -> locked |> Map.get("attempts", []) |> normalize_attempts()
        _locked -> []
      end

    attempts = attempts ++ locked_attempts
    flake_policy = normalize_policy(Map.get(details, "flake_policy", %{}))

    cond do
      attempts == [] ->
        []

      flake_detected?(attempts) and not flake_policy["allowed"] ->
        [
          stage_finding(
            "disallowed_flake_retry",
            "A flaky test retry was used without policy approval."
          )
        ]

      retry_count(attempts) > flake_policy["max_retries"] ->
        [
          stage_finding(
            "retry_limit_exceeded",
            "Test retry count exceeded the flake policy limit."
          )
        ]

      unresolved_infra_failure?(attempts) ->
        [
          stage_finding(
            "unresolved_infra_retry",
            "Infrastructure retry did not end in a passing attempt."
          )
        ]

      true ->
        []
    end
  end

  defp acceptance_mapping_findings(details) do
    required_criteria = required_acceptance_criteria(details)
    results_by_id = acceptance_results_by_id(details)

    Enum.flat_map(required_criteria, fn criterion_id ->
      case Map.get(results_by_id, criterion_id) do
        nil ->
          [
            stage_finding(
              "missing_acceptance_result",
              "Acceptance criterion #{criterion_id} is missing a gate result.",
              %{"criterion_id" => criterion_id}
            )
          ]

        result ->
          acceptance_result_findings(criterion_id, result)
      end
    end)
  end

  defp required_acceptance_criteria(details) do
    locked_acceptance =
      case Map.get(details, "locked_acceptance") do
        locked when is_map(locked) -> locked
        _locked -> %{}
      end

    (Map.get(details, "required_acceptance_criteria") ||
       Map.get(details, "acceptance_criteria") ||
       Map.get(locked_acceptance, "required_criteria") ||
       Map.get(locked_acceptance, "acceptance_criteria") ||
       [])
    |> Enum.map(&criterion_id/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp acceptance_results_by_id(details) do
    locked_acceptance =
      case Map.get(details, "locked_acceptance") do
        locked when is_map(locked) -> locked
        _locked -> %{}
      end

    results =
      Map.get(details, "acceptance_results") ||
        Map.get(locked_acceptance, "acceptance_results") ||
        []

    case results do
      results when is_map(results) ->
        Map.new(results, fn {criterion_id, result} -> {to_string(criterion_id), result} end)

      results when is_list(results) ->
        Map.new(results, fn result -> {criterion_id(result), result} end)

      _results ->
        %{}
    end
  end

  defp acceptance_result_findings(criterion_id, result) when is_map(result) do
    status = detail_status(Map.get(result, "status"))
    skip_allowed? = explicit_allowance?(result, "skip_allowed")
    missing_evidence_allowed? = explicit_allowance?(result, "missing_evidence_allowed")

    [
      cond do
        status == "skipped" and not skip_allowed? ->
          stage_finding(
            "skipped_acceptance_result",
            "Acceptance criterion #{criterion_id} was skipped without explicit allowance.",
            %{"criterion_id" => criterion_id}
          )

        not passed?(status) and status != "skipped" ->
          stage_finding(
            "acceptance_result_not_passed",
            "Acceptance criterion #{criterion_id} did not pass.",
            %{"criterion_id" => criterion_id, "status" => status}
          )

        true ->
          nil
      end,
      unless evidence_refs_present?(result) or missing_evidence_allowed? or
               (status == "skipped" and skip_allowed?) do
        stage_finding(
          "missing_acceptance_evidence",
          "Acceptance criterion #{criterion_id} is missing evidence refs.",
          %{"criterion_id" => criterion_id}
        )
      end
    ]
  end

  defp acceptance_result_findings(criterion_id, _result) do
    [
      stage_finding(
        "invalid_acceptance_result",
        "Acceptance criterion #{criterion_id} result must be a map.",
        %{"criterion_id" => criterion_id}
      )
    ]
  end

  defp stage_finding(failure_category, message, details \\ %{}) do
    %{
      "schema_version" => "conveyor.gate_stage_finding@1",
      "category" => "gate_test_execution",
      "failure_category" => failure_category,
      "severity" => "blocking",
      "message" => message,
      "action" => "block_gate",
      "details" => details
    }
  end

  defp blocking_findings(findings) do
    Enum.filter(findings, &(&1["severity"] == "blocking"))
  end

  defp evidence_refs_present?(map) when is_map(map) do
    refs = Map.get(map, "evidence_refs") || Map.get(map, "evidence_ref") || []

    refs
    |> List.wrap()
    |> Enum.any?(&(is_binary(&1) and &1 != ""))
  end

  defp normalize_attempts(attempts) when is_list(attempts), do: attempts
  defp normalize_attempts(_attempts), do: []

  defp normalize_policy(policy) when is_map(policy) do
    %{
      "allowed" => Map.get(policy, "allowed", true),
      "max_retries" => Map.get(policy, "max_retries", 0)
    }
  end

  defp normalize_policy(_policy), do: %{"allowed" => true, "max_retries" => 0}

  defp flake_detected?(attempts) do
    Enum.any?(attempts, fn attempt ->
      Map.get(attempt, "classification") == "flake" or
        detail_status(Map.get(attempt, "status")) == "flaky"
    end)
  end

  defp retry_count(attempts), do: max(length(attempts) - 1, 0)

  defp unresolved_infra_failure?(attempts) do
    Enum.any?(attempts, &(Map.get(&1, "classification") == "infra")) and
      not passed?(detail_status(List.last(attempts)["status"]))
  end

  defp criterion_id(%{"criterion_id" => criterion_id}), do: to_string(criterion_id)
  defp criterion_id(%{"ac_id" => criterion_id}), do: to_string(criterion_id)
  defp criterion_id(%{criterion_id: criterion_id}), do: to_string(criterion_id)
  defp criterion_id(%{ac_id: criterion_id}), do: to_string(criterion_id)
  defp criterion_id(criterion_id) when is_binary(criterion_id), do: criterion_id
  defp criterion_id(_criterion), do: nil

  defp explicit_allowance?(result, key) do
    Map.get(result, key) == true and allowance_reason(result, key) not in [nil, ""]
  end

  defp allowance_reason(result, "skip_allowed") do
    Map.get(result, "skip_reason") || Map.get(result, "allowance_reason")
  end

  defp allowance_reason(result, "missing_evidence_allowed") do
    Map.get(result, "missing_evidence_reason") || Map.get(result, "allowance_reason")
  end

  defp transition_plan("pass", attrs, _failure_findings) do
    context = transition_context(attrs, true, "pass", nil)

    %{
      "run_attempt" => %{"allowed" => true, "transition" => "gate", "context" => context},
      "slice" => %{"allowed" => true, "transition" => "gate", "context" => context}
    }
  end

  defp transition_plan("fail", attrs, failure_findings) do
    failed_stages = Enum.map(failure_findings, & &1["stage_key"])
    reason = "required gate stages failed: #{Enum.join(failed_stages, ", ")}"
    context = transition_context(attrs, false, "fail", reason)

    %{
      "run_attempt" => %{
        "allowed" => false,
        "blocked_by" => failed_stages,
        "context" => context
      },
      "slice" => %{
        "allowed" => false,
        "blocked_by" => failed_stages,
        "context" => context
      }
    }
  end

  defp transition_context(attrs, gate_complete?, decision, reason) do
    %{
      "gate_complete" => gate_complete?,
      "gate_decision" => decision,
      "gate_status" => decision,
      "gate_result_id" => PayloadHelpers.fetch_required!(attrs, :gate_result_id),
      "gate_version" => PayloadHelpers.fetch_required!(attrs, :gate_version),
      "policy_digest" => PayloadHelpers.fetch_required!(attrs, :policy_digest),
      "contract_lock_digest" => PayloadHelpers.fetch_required!(attrs, :contract_lock_digest),
      "canary_suite_version" => PayloadHelpers.fetch_required!(attrs, :canary_suite_version)
    }
    |> put_if_present("reason", reason)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
