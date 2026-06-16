defmodule Conveyor.Repo do
  @moduledoc """
  Postgres repository for the Conveyor control plane.
  """

  use AshPostgres.Repo, otp_app: :conveyor

  def installed_extensions do
    ["ash-functions"]
  end

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
