defmodule Mix.Tasks.Conveyor.ConfigProbe do
  @moduledoc """
  Writes resolved `.conveyor/config.toml` evidence as JSON.

      mix conveyor.config_probe --config .conveyor/config.toml --output tmp/conveyor_config_probe.json

  Pass `--locked-run-spec path/to/run_spec.json` to verify that project-local
  config still matches a locked RunSpec before station execution.
  """

  use Mix.Task

  @shortdoc "Write Conveyor project-config resolution evidence"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [config: :string, output: :string, locked_run_spec: :string]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    config_path = Keyword.get(opts, :config, Conveyor.ProjectConfig.default_path())
    output_path = Keyword.get(opts, :output, "tmp/conveyor_config_probe.json")
    locked_run_spec = load_locked_run_spec(Keyword.get(opts, :locked_run_spec))

    case Conveyor.ProjectConfig.load(config_path, locked_run_spec: locked_run_spec) do
      {:ok, _config, event} ->
        write_json!(output_path, event)

      {:error, event} ->
        write_json!(output_path, event)
        Mix.raise("conveyor config probe failed; see #{output_path}")
    end
  end

  defp load_locked_run_spec(nil), do: nil

  defp load_locked_run_spec(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_json!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end
end
