defmodule Conveyor.Oban do
  @moduledoc """
  Oban facade for the Conveyor supervision tree.
  """

  use Oban, otp_app: :conveyor
end
