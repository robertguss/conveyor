defmodule Mix.Tasks.Conveyor.VersionProbe do
  @moduledoc """
  Writes boot and runtime-version evidence for Conveyor.

      mix conveyor.version_probe --output tmp/version_probe.json --boot-log tmp/boot.log

  Pass `--skip-db` when the caller only wants to verify the BEAM supervision tree
  and record the required Postgres major version without querying a database.
  """

  use Mix.Task

  @shortdoc "Write Conveyor boot/version evidence"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, boot_log: :string, skip_db: :boolean]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    output_path = Keyword.get(opts, :output, "tmp/conveyor_version_probe.json")
    boot_log_path = Keyword.get(opts, :boot_log, "tmp/conveyor_boot.log")

    result = Conveyor.VersionProbe.run(database_probe?: !Keyword.get(opts, :skip_db, false))

    write_json!(output_path, result)
    write_text!(boot_log_path, Enum.join(result.boot_log, "\n") <> "\n")

    if result.status != "ok" do
      Mix.raise("conveyor version probe failed; see #{output_path} and #{boot_log_path}")
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
