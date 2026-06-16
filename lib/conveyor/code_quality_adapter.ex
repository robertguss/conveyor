defmodule Conveyor.CodeQualityAdapter do
  @moduledoc """
  Structured quality-adapter contract for tracer evidence.

  Quality adapters are evidence inputs. They describe what would be checked,
  which local requirements are needed, and whether missing requirements block the
  gate. The default sample path can therefore emit ContextPack and gate
  references even when no proprietary quality service is installed.
  """

  @config_schema_version "conveyor.code_quality_adapter.config@1"
  @run_schema_version "conveyor.code_quality_adapter.run@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"

  def config_summary(profile_id, profile) when is_binary(profile_id) and is_map(profile) do
    profile = normalize_profile(profile)
    refs = quality_refs(profile_id, profile)

    %{
      schema_version: @config_schema_version,
      matrix_ref: @matrix_ref,
      profile_id: profile_id,
      adapter: profile["adapter"],
      mode: profile["mode"],
      blocking: profile["blocking"],
      checks: profile["checks"],
      required_tools: profile["required_tools"],
      required_env_keys: profile["required_env_keys"],
      consumers: profile["consumers"],
      quality_refs: refs
    }
  end

  def run_profile(profile_id, profile, opts \\ [])
      when is_binary(profile_id) and is_map(profile) and is_list(opts) do
    profile = normalize_profile(profile)
    resolver = Keyword.get(opts, :tool_resolver, &System.find_executable/1)
    env = Keyword.get(opts, :env, System.get_env())
    findings = adapter_findings(profile) ++ requirement_findings(profile, resolver, env)
    check_results = check_results(profile, findings)

    %{
      schema_version: @run_schema_version,
      matrix_ref: @matrix_ref,
      profile_id: profile_id,
      adapter: profile["adapter"],
      mode: profile["mode"],
      blocking: profile["blocking"],
      status: run_status(profile, findings),
      blocks_gate: blocks_gate?(findings),
      checks: check_results,
      findings: findings,
      quality_refs: quality_refs(profile_id, profile)
    }
  end

  def quality_refs(profile_id, profile) when is_binary(profile_id) and is_map(profile) do
    profile = normalize_profile(profile)
    digest = profile_digest(profile_id, profile)
    required? = profile["blocking"]

    %{
      context_pack: %{
        schema_version: "conveyor.context_pack.quality_ref@1",
        profile_id: profile_id,
        adapter: profile["adapter"],
        mode: profile["mode"],
        digest: digest,
        required: required?
      },
      gate: %{
        schema_version: "conveyor.gate.quality_ref@1",
        profile_id: profile_id,
        adapter: profile["adapter"],
        mode: profile["mode"],
        digest: digest,
        required: required?,
        advisory: not required?
      }
    }
  end

  def normalize_profile(profile) when is_map(profile) do
    adapter = Map.get(profile, "adapter", "noop")
    blocking = blocking?(profile)
    mode = if(blocking, do: "blocking", else: Map.get(profile, "mode", "advisory"))

    profile
    |> Map.put("adapter", adapter)
    |> Map.put("mode", mode)
    |> Map.put("blocking", blocking)
    |> Map.put("checks", string_list(profile["checks"], default_checks(adapter)))
    |> Map.put("required_tools", string_list(profile["required_tools"], []))
    |> Map.put("required_env_keys", string_list(profile["required_env_keys"], []))
    |> Map.put("consumers", string_list(profile["consumers"], ["context_pack", "gate"]))
  end

  defp adapter_findings(%{"adapter" => "noop", "blocking" => false}) do
    [
      %{
        code: "noop_quality_adapter",
        severity: "info",
        message: "Noop quality adapter recorded an advisory evidence reference",
        blocks_gate: false
      }
    ]
  end

  defp adapter_findings(_profile), do: []

  defp requirement_findings(profile, resolver, env) do
    tool_findings =
      profile["required_tools"]
      |> Enum.reject(&(resolver.(&1) |> present?()))
      |> Enum.map(fn tool ->
        requirement_finding(
          profile,
          "missing_quality_tool",
          "required quality tool #{tool} is not available",
          %{tool: tool}
        )
      end)

    env_findings =
      profile["required_env_keys"]
      |> Enum.reject(&(Map.get(env, &1) |> present?()))
      |> Enum.map(fn key ->
        requirement_finding(
          profile,
          "missing_quality_credential",
          "required quality credential #{key} is not available",
          %{env_key: key}
        )
      end)

    tool_findings ++ env_findings
  end

  defp requirement_finding(%{"blocking" => true}, code, message, details) do
    %{
      code: code,
      severity: "error",
      message: message,
      details: details,
      blocks_gate: true
    }
  end

  defp requirement_finding(_profile, code, message, details) do
    %{
      code: code,
      severity: "warn",
      message: message,
      details: details,
      blocks_gate: false
    }
  end

  defp check_results(profile, findings) do
    missing? =
      Enum.any?(findings, &(&1.code in ~w(missing_quality_tool missing_quality_credential)))

    status = if missing?, do: "requirements_missing", else: "configured"

    Enum.map(profile["checks"], fn check ->
      %{
        name: check,
        status: status,
        adapter: profile["adapter"],
        advisory: not profile["blocking"],
        blocks_gate: profile["blocking"] and missing?
      }
    end)
  end

  defp run_status(_profile, findings) do
    cond do
      blocks_gate?(findings) -> "blocked"
      Enum.any?(findings, &(&1.severity == "warn")) -> "advisory_warning"
      true -> "advisory_pass"
    end
  end

  defp blocks_gate?(findings), do: Enum.any?(findings, &Map.get(&1, :blocks_gate, false))

  defp profile_digest(profile_id, profile) do
    canonical =
      %{profile_id: profile_id, profile: profile}
      |> canonical_term()
      |> :erlang.term_to_binary()

    digest =
      :crypto.hash(:sha256, canonical)
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested_value} -> {to_string(key), canonical_term(nested_value)} end)
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp default_checks("noop"), do: ["quality_ref"]
  defp default_checks("local_python"), do: ["py_compile"]
  defp default_checks("python"), do: ["py_compile"]
  defp default_checks(_adapter), do: []

  defp string_list(value, _default) when is_list(value), do: value
  defp string_list(nil, default), do: default
  defp string_list(_value, default), do: default

  defp blocking?(profile) do
    truthy?(Map.get(profile, "blocking")) or Map.get(profile, "mode") == "blocking"
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp present?(value), do: is_binary(value) and value != ""
end

defmodule Conveyor.CodeQualityAdapter.Noop do
  @moduledoc "No-op advisory profile used when no local or proprietary quality tooling is required."

  def profile do
    %{
      "adapter" => "noop",
      "mode" => "advisory",
      "blocking" => false,
      "checks" => ["quality_ref"],
      "required_tools" => [],
      "required_env_keys" => [],
      "consumers" => ["context_pack", "gate"]
    }
  end
end

defmodule Conveyor.CodeQualityAdapter.LocalPython do
  @moduledoc "Local advisory Python profile for the sterile FastAPI sample."

  def profile do
    %{
      "adapter" => "local_python",
      "mode" => "advisory",
      "blocking" => false,
      "checks" => ["py_compile", "pytest_collect"],
      "required_tools" => ["python3"],
      "required_env_keys" => [],
      "consumers" => ["context_pack", "gate"]
    }
  end
end

defmodule Conveyor.CodeQualityAdapter.CodeScent do
  @moduledoc "Explicit blocking CodeScent profile shape for advanced deployments."

  def profile do
    %{
      "adapter" => "codescent",
      "mode" => "blocking",
      "blocking" => true,
      "checks" => ["codescent_gate"],
      "required_tools" => ["codescent"],
      "required_env_keys" => ["CODESCENT_API_KEY"],
      "consumers" => ["gate"]
    }
  end
end
