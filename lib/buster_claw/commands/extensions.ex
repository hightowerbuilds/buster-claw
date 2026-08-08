defmodule BusterClaw.Commands.Extensions do
  @moduledoc """
  Extension commands. Delegated to from `BusterClaw.Commands`.

  This module is the one place that knows about both `BusterClaw.Extensions` and
  `BusterClaw.Skills` — Extensions hands out paths and never calls Skills, which
  is what keeps `Skills → Extensions` a one-way edge. Validating a freshly
  written part is a caller's job, and this is the caller.
  """

  alias BusterClaw.{Extensions, Skills}

  def extension_list(_args) do
    {:ok, Enum.map(Extensions.list(), &summary_view/1)}
  end

  def extension_show(%{"id" => id}) do
    case Extensions.fetch(id) do
      {:ok, manifest} ->
        {:ok,
         manifest
         |> summary_view()
         |> Map.merge(%{
           enabled: Extensions.enabled?(id),
           parts: parts_view(id),
           body: manifest.body
         })}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :not_found}
    end
  end

  def extension_show(_args), do: {:error, :missing_id}

  def extension_enable(%{"id" => id}) do
    case Extensions.enable(id) do
      {:ok, manifest} -> {:ok, %{enabled: manifest.id, name: manifest.name}}
      {:error, reason} -> {:error, reason}
    end
  end

  def extension_enable(_args), do: {:error, :missing_id}

  def extension_disable(%{"id" => id}) do
    case Extensions.disable(id) do
      :ok -> {:ok, %{disabled: id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def extension_disable(_args), do: {:error, :missing_id}

  @doc """
  Attach a part. The part lands disabled; we then load it back through
  `Skills.load/1` and report whether it parses, so the author gets the real
  validator's verdict rather than a hopeful "written".

  A part that does not parse is **removed again**. Leaving an unparseable file in
  an extension directory would be a broken instruction sitting where a reviewed
  one belongs, and the next `Skills` scan would log a warning for it forever.
  """
  def extension_add_part(%{"id" => id, "name" => name, "body" => body} = args) do
    attrs = %{
      name: name,
      body: body,
      description: Map.get(args, "description", ""),
      kind: kind(Map.get(args, "kind")),
      steps: Map.get(args, "steps")
    }

    with {:ok, path} <- Extensions.add_part(id, attrs),
         :ok <- verify(name, path) do
      {:ok,
       %{
         extension: id,
         part: name,
         path: path,
         enabled: false,
         note:
           "Written disabled. An operator must read it and set `enabled: true` before it does anything."
       }}
    end
  end

  def extension_add_part(_args), do: {:error, :missing_args}

  # --- internals ---------------------------------------------------------

  defp verify(name, path) do
    case Skills.load(name) do
      {:ok, _skill} ->
        :ok

      {:error, reason} ->
        File.rm(path)
        {:error, {:invalid_part, reason}}

      nil ->
        # Written, but not resolvable — the extension is switched off, so its
        # parts are not on the search path. That is correct behaviour, not a
        # failure: the file is in the right place and will validate when the
        # extension is enabled.
        :ok
    end
  end

  defp kind("composition"), do: :composition
  defp kind(_other), do: :reference

  defp summary_view(manifest) do
    Map.take(manifest, [
      :id,
      :name,
      :version,
      :summary,
      :surface,
      :network,
      :writes,
      :money,
      :bundled
    ])
  end

  defp parts_view(id) do
    case File.ls(Extensions.parts_dir(id)) do
      {:ok, files} ->
        files
        |> Enum.filter(&(Path.extname(&1) == ".md"))
        |> Enum.map(&Path.basename(&1, ".md"))
        |> Enum.sort()

      _ ->
        []
    end
  end
end
