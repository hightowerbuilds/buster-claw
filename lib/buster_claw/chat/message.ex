defmodule BusterClaw.Chat.Message do
  @moduledoc "A chat message held by a local chat session."

  @enforce_keys [:role, :content]
  defstruct [:role, :content]
end
