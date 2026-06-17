defmodule Mix.Tasks.Conveyor.PlanAudit do
  @moduledoc """
  Emits deterministic PlanAudit JSON for a normalized plan source.

      mix conveyor.plan_audit plans/phase1.md
      mix conveyor.plan_audit plans/phase1.md --output tmp/plan_audit.json
  """

  use Mix.Task

  @shortdoc "Audit a conveyor.plan@1 source for handoff readiness"

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [output: :string])

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    source_path =
      case argv do
        [path] -> path
        [] -> Mix.raise("expected a plan source path")
        _many -> Mix.raise("expected exactly one plan source path")
      end

    report = Conveyor.PlanAudit.audit_file(source_path)

    if output_path = Keyword.get(opts, :output) do
      write_json!(output_path, report)
    end

    Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true))

    if report.exit_code != 0 do
      System.halt(report.exit_code)
    end
  end

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
