defmodule Mix.Tasks.Conveyor.OperatorShell do
  @moduledoc false

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    shortdoc = Keyword.fetch!(opts, :shortdoc)
    moduledoc = Keyword.fetch!(opts, :moduledoc)

    quote bind_quoted: [id: id, shortdoc: shortdoc, moduledoc: moduledoc] do
      use Mix.Task

      @shortdoc shortdoc
      @moduledoc moduledoc
      @operator_task_id id

      @impl true
      def run(args) do
        Conveyor.OperatorTasks.run_mix_task!(@operator_task_id, args)
      end
    end
  end
end

defmodule Mix.Tasks.Conveyor.Init do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "init",
    shortdoc: "Prepare Conveyor project bootstrap inputs",
    moduledoc: """
    Prepares Conveyor project bootstrap inputs.

        mix conveyor.init --json
        mix conveyor.init --output tmp/conveyor_operator/init.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.SeedSample do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "seed_sample",
    shortdoc: "Prepare sample app inputs for demos",
    moduledoc: """
    Prepares sample app inputs for Conveyor demos.

        mix conveyor.seed_sample --json
        mix conveyor.seed_sample --output tmp/conveyor_operator/seed_sample.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Demo do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "demo",
    shortdoc: "Run the deterministic Conveyor demo shell",
    moduledoc: """
    Runs the deterministic Conveyor demo shell.

        mix conveyor.demo --json
        mix conveyor.demo --output tmp/conveyor_operator/demo.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Show do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "show",
    shortdoc: "Show Conveyor run and project state",
    moduledoc: """
    Shows Conveyor run and project state.

        mix conveyor.show --json
        mix conveyor.show --output tmp/conveyor_operator/show.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.RunSlice do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "run_slice",
    shortdoc: "Start a bounded Conveyor run slice",
    moduledoc: """
    Starts a bounded Conveyor run slice.

        mix conveyor.run_slice --json
        mix conveyor.run_slice --output tmp/conveyor_operator/run_slice.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Verify do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "verify",
    shortdoc: "Verify recorded Conveyor evidence",
    moduledoc: """
    Verifies recorded Conveyor evidence.

        mix conveyor.verify --json
        mix conveyor.verify --output tmp/conveyor_operator/verify.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.GateCanary do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "gate_canary",
    shortdoc: "Run gate-policy canary checks",
    moduledoc: """
    Runs gate-policy canary checks.

        mix conveyor.gate_canary --json
        mix conveyor.gate_canary --output tmp/conveyor_operator/gate_canary.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Report do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "report",
    shortdoc: "Render a Conveyor operator report",
    moduledoc: """
    Renders a Conveyor operator report.

        mix conveyor.report --json
        mix conveyor.report --output tmp/conveyor_operator/report.json
        mix conveyor.report --artifact-manifest tmp/conveyor_operator/artifacts.json --root .

    This command is deterministic, verifies stored artifact digests before
    projection, and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Replay do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "replay",
    shortdoc: "Replay Conveyor evidence deterministically",
    moduledoc: """
    Replays Conveyor evidence deterministically.

        mix conveyor.replay --json
        mix conveyor.replay --output tmp/conveyor_operator/replay.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.ContractDiff do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "contract_diff",
    shortdoc: "Diff Conveyor contracts and schemas",
    moduledoc: """
    Diffs Conveyor contracts and schemas.

        mix conveyor.contract_diff --json
        mix conveyor.contract_diff --output tmp/conveyor_operator/contract_diff.json

    This skeleton is deterministic and never contacts live providers.
    """
end

defmodule Mix.Tasks.Conveyor.Ci do
  use Mix.Tasks.Conveyor.OperatorShell,
    id: "ci",
    shortdoc: "Run the Conveyor operator CI shell",
    moduledoc: """
    Runs the Conveyor operator CI shell.

        mix conveyor.ci --json
        mix conveyor.ci --output tmp/conveyor_operator/ci.json

    This skeleton is deterministic and never contacts live providers.
    """
end
