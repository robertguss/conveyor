defmodule Conveyor.Domain do
  @moduledoc """
  Root Ash domain for the control-plane resources.

  Phase 0 keeps the domain empty. Resource modules and migrations are introduced
  by the domain-state beads that depend on the application scaffold.
  """

  use Ash.Domain, otp_app: :conveyor

  resources do
  end
end
