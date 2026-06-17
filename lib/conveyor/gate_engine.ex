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

    %{
      "schema_version" => "conveyor.gate_stage_result@1",
      "stage_key" => stage_key,
      "required" => required,
      "status" => status,
      "passed" => passed?(status),
      "next_action" => next_action(stage, stage_key, required, status),
      "details" =>
        stage
        |> PayloadHelpers.get(:details, PayloadHelpers.get(stage, :metadata, %{}))
        |> PayloadHelpers.normalize_map()
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

  defp required_failure?(%{"required" => true, "passed" => false}), do: true
  defp required_failure?(_stage), do: false

  defp passed?(status), do: MapSet.member?(@pass_statuses, status)

  defp next_action(stage, stage_key, true, status) do
    PayloadHelpers.get(stage, :next_action) ||
      if passed?(status), do: nil, else: "resolve_#{stage_key}_before_gate"
  end

  defp next_action(stage, _stage_key, false, _status), do: PayloadHelpers.get(stage, :next_action)

  defp failure_finding(stage) do
    %{
      "schema_version" => @finding_schema_version,
      "category" => "required_gate_stage_failed",
      "severity" => "blocking",
      "matrix_ref" => @matrix_ref,
      "harness_ref" => @harness_ref,
      "finding_ref" => "gate-required-stage-failed:#{stage["stage_key"]}",
      "stage_key" => stage["stage_key"],
      "stage_status" => stage["status"],
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
      "details" => stage["details"]
    }
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
