defmodule Conveyor.VersionProbeTest do
  use ExUnit.Case, async: false

  test "records runtime versions and supervised service status" do
    result = Conveyor.VersionProbe.run(database_probe?: false)

    assert result.status == "ok"
    assert result.postgres.status == "skipped"
    assert result.postgres.required_major == 16
    assert result.versions.elixir
    assert result.versions.otp
    assert Enum.any?(result.services, &(&1.name == "repo" and &1.status == "started"))
    assert Enum.any?(result.services, &(&1.name == "endpoint" and &1.status == "started"))
    assert Enum.any?(result.services, &(&1.name == "oban" and &1.status == "started"))
  end
end
