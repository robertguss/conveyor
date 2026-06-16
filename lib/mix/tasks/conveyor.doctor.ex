defmodule Mix.Tasks.Conveyor.Doctor do
  @moduledoc """
  Checks local prerequisites for running the Conveyor tracer.

      mix conveyor.doctor --output tmp/conveyor_doctor.json --transcript tmp/conveyor_doctor.log

  Blocking failures exit with code 4 and include stable categories plus
  NextAction guidance in the JSON report.
  """

  use Mix.Task

  @shortdoc "Check Conveyor runtime prerequisites"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [config: :string, output: :string, transcript: :string, json: :boolean]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    report =
      Conveyor.Doctor.run(
        config_path: Keyword.get(opts, :config, Conveyor.ProjectConfig.default_path())
      )

    output_path = Keyword.get(opts, :output, "tmp/conveyor_doctor.json")
    transcript_path = Keyword.get(opts, :transcript, "tmp/conveyor_doctor.log")

    write_json!(output_path, report)
    write_text!(transcript_path, report.transcript <> "\n")

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Jason.encode_to_iodata!(report, pretty: true))
    else
      Mix.shell().info(report.transcript)
      Mix.shell().info("doctor report: #{output_path}")
    end

    if report.exit_code != 0 do
      System.halt(report.exit_code)
    end
  end

  defp write_json!(path, data) do
    ensure_parent!(path)
    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end

  defp write_text!(path, data) do
    ensure_parent!(path)
    File.write!(path, data)
  end

  defp ensure_parent!(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
