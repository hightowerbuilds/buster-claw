defmodule BusterClawWeb.ShaderController do
  @moduledoc """
  Serves a custom shader's raw WGSL body to the `SmokeBackground` hook, which
  prepends the bundled prelude and compiles it live via WebGPU. Loopback-only
  (no pipeline, like the `/ws` and `/appearance` asset routes); the name is
  guarded by `Shaders.read/1` against traversal.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Shaders

  def show(conn, %{"name" => name}) do
    case Shaders.read(name) do
      {:ok, wgsl} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, wgsl)

      {:error, _reason} ->
        send_resp(conn, 404, "shader not found")
    end
  end
end
