defmodule BusterClaw.Repo do
  use Ecto.Repo,
    otp_app: :buster_claw,
    adapter: Ecto.Adapters.SQLite3
end
