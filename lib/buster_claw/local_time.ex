defmodule BusterClaw.LocalTime do
  @moduledoc "Local date helpers for the desktop runtime."

  def today do
    case Application.get_env(:buster_claw, :local_today) do
      %Date{} = date -> date
      _other -> :erlang.date() |> Date.from_erl!()
    end
  end
end
