defmodule BusterClaw.Shaders do
  @moduledoc """
  Custom homepage shader patterns — the runtime-loadable, file-first layer of the
  background system.

  A custom shader is one WGSL file at `<workspace>/shaders/<name>.wgsl` containing
  a fragment entry point `fs_main`. The shared prelude
  (`assets/js/smoke/prelude.wgsl.js`, bundled into the app) is prepended in the
  browser and the WGSL is compiled live via WebGPU — so a new pattern needs **no
  recompile and no rebuild**, unlike the built-in shaders baked into the JS bundle.

  This module only lists / reads / validates the files (file-first, git-diffable,
  operator- and agent-editable, exactly like skills and jobs). Selection lives in
  `BusterClaw.Appearance`; rendering lives in the `SmokeBackground` hook, which
  fetches the WGSL from `GET /shaders/:name`. The prelude contract an author must
  follow is documented in the `shader-designer` reference skill.

  Safety: WGSL runs in the WebGPU sandbox (no memory/IO escape). A shader only
  renders when the **user selects it** in Settings → Appearance — an author can
  propose a pattern but never force it onto the screen. Reads are size-capped and
  must define `fs_main`; the browser compile-checks and falls back on error.
  """
  require Logger

  alias BusterClaw.Library.Artifact

  @subdir "shaders"
  @roster "README.md"
  @ext ".wgsl"
  @max_bytes 64_000
  @name_re ~r/\A[a-z0-9][a-z0-9-]*\z/

  def dir, do: Artifact.workspace_path(@subdir)
  def path(name), do: Path.join(dir(), name <> @ext)

  @doc "Names of valid custom shaders (files that read + validate), sorted."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&shader_file?/1)
        |> Enum.map(&Path.rootname/1)
        |> Enum.filter(&exists?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc "True when `name` is a valid, existing, well-formed custom shader."
  def exists?(name) when is_binary(name), do: match?({:ok, _}, read(name))
  def exists?(_), do: false

  @doc """
  Read + validate a custom shader's WGSL body. Returns `{:ok, wgsl}` or
  `{:error, :invalid_name | :not_found | :too_large | :missing_fs_main}`. The name
  guard (and the single `:name` path segment) prevent traversal.
  """
  def read(name) when is_binary(name) do
    with true <- Regex.match?(@name_re, name),
         {:ok, body} <- File.read(path(name)),
         :ok <- validate(body) do
      {:ok, body}
    else
      false -> {:error, :invalid_name}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(_name), do: {:error, :invalid_name}

  defp validate(body) do
    cond do
      byte_size(body) > @max_bytes -> {:error, :too_large}
      not String.contains?(body, "fn fs_main") -> {:error, :missing_fs_main}
      true -> :ok
    end
  end

  @doc "Seed the `shaders/` dir with a README (never overwrites operator files)."
  def ensure do
    File.mkdir_p!(dir())
    roster = Path.join(dir(), @roster)
    unless File.exists?(roster), do: File.write(roster, default_roster())
    :ok
  rescue
    error ->
      Logger.warning("Shaders.ensure failed: #{Exception.message(error)}")
      :error
  end

  defp shader_file?(name), do: Path.extname(name) == @ext

  defp default_roster do
    """
    # Custom shader patterns

    Each `<name>.wgsl` here is a homepage background pattern you can select in
    Settings → Appearance — no recompile. The file holds **only** the WGSL
    fragment entry point (`fn fs_main(...) -> @location(0) vec4<f32>`); the shared
    prelude (uniforms + `hash`/`fbm`/`grad3`/`bg_post` helpers, and the `colA`/
    `colB`/`colC` palette) is prepended automatically and the shader is compiled
    live in the browser via WebGPU.

    Read the `shader-designer` skill (`skills/shader-designer.md`) for the full
    prelude contract and worked examples. A shader only renders when you select
    it — authoring a file never forces it onto the screen. Names are `[a-z0-9-]`;
    a name matching a built-in (smoke/waves/mandel/weather) is shadowed by
    the built-in.
    """
  end
end
