defmodule Conveyor.ApplicationSmokeTest do
  use ExUnit.Case, async: false

  test "boots the control-plane supervision tree" do
    {:ok, started_apps} = Application.ensure_all_started(:conveyor)

    on_exit(fn ->
      started_apps
      |> Enum.reverse()
      |> Enum.each(&Application.stop/1)
    end)

    assert Process.whereis(Conveyor.Repo)
    assert Process.whereis(ConveyorWeb.Endpoint)
    assert supervised_child_started?(Conveyor.Oban)
    assert Process.whereis(Conveyor.PubSub)
  end

  defp supervised_child_started?(child_id) do
    case Supervisor.which_children(Conveyor.Supervisor) |> List.keyfind(child_id, 0) do
      {^child_id, pid, _type, _modules} when is_pid(pid) -> true
      _missing -> false
    end
  end
end
