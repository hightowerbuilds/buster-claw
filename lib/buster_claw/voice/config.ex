defmodule BusterClaw.Voice.Config do
  @moduledoc """
  What the engine is told, every time it is asked for a line.

  Six knobs, all optional, all stored in one Settings row. Absent means the
  engine's own default — which is exactly what every render did before this
  module existed, so an empty config changes nothing.

  ## Applied at the call site, not inside `Engine`

  `Engine` builds argv from explicit options and stays pure: it reads no
  settings, so its tests need no database. This module turns the stored knobs
  into that options list (`render_opts/0`), and `Chimes` and `Greeting` merge it
  under whatever a caller passed explicitly. The one exception is
  `engine_path/0`, which `Engine.resolve/0` has to consult because resolution
  takes no options — and it reads it fail-soft, because resolution also runs
  from processes that have no database connection.

  ## Changing any of these re-renders everything

  The render cache is keyed on the full argv. Switching the device, adding a
  reference clip or nudging the step count is a different ask, so it is a
  different file — and every chime already made is now stale. That is correct
  (a chime rendered in the old voice *should* be replaced) and it is expensive on
  a slow machine, so the settings page says so in numbers rather than letting the
  operator find out by pressing the button.

  ## The reference clip is the whole point

  With `reference_audio` set, every render becomes `clone` rather than `design`:
  the engine is handed a few seconds of the operator's own voice and asked to
  speak in it. Nothing else here matters as much. It is validated as a real file
  on save, and `Renderer` refuses to render if it has gone missing since —
  cloning nothing is not a render, it is a silent fallback to a stranger's voice.
  """

  alias BusterClaw.Settings

  @key "voice_engine_config"

  @devices ~w(cpu mps cuda)

  @type t :: %{
          device: String.t() | nil,
          reference_audio: String.t() | nil,
          control: String.t() | nil,
          inference_timesteps: pos_integer() | nil,
          cfg_value: float() | nil,
          engine_path: String.t() | nil
        }

  @empty %{
    device: nil,
    reference_audio: nil,
    control: nil,
    inference_timesteps: nil,
    cfg_value: nil,
    engine_path: nil
  }

  @doc "The stored knobs, with `nil` for anything left at the engine's default."
  @spec get() :: t()
  def get do
    case Settings.get(@key) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> Map.merge(@empty, atomize(map))
          _ -> @empty
        end

      _ ->
        @empty
    end
  rescue
    # No repo, no connection, wrong process — a config read that cannot happen
    # reads as defaults. Every default is the engine's own, so this is always
    # safe and never hides a real setting: a stored value is read the next time.
    _ -> @empty
  catch
    :exit, _ -> @empty
  end

  @doc """
  Store a set of knobs. Blank strings clear a knob; each is validated in the
  shape the engine will accept.
  """
  @spec put(map()) :: :ok | {:error, {atom(), term()}}
  def put(attrs) when is_map(attrs) do
    with {:ok, clean} <- validate(attrs) do
      merged = Map.merge(get(), clean)

      case Settings.put(@key, Jason.encode!(compact(merged))) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:settings, reason}}
      end
    end
  end

  @doc "Clear every knob."
  @spec reset() :: :ok
  def reset do
    Settings.put(@key, "{}")
    :ok
  end

  @doc """
  The stored knobs as the options `Engine`'s argv builders take, with unset ones
  omitted so an explicit caller option or the engine default fills in.
  """
  @spec render_opts() :: keyword()
  def render_opts do
    config = get()

    [
      device: config.device,
      reference_audio: config.reference_audio,
      control: config.control,
      inference_timesteps: config.inference_timesteps,
      cfg_value: config.cfg_value
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "An explicit engine location, if the operator set one."
  @spec engine_path() :: String.t() | nil
  def engine_path, do: get().engine_path

  @doc "True when a reference clip is set — every render is a clone of it."
  @spec cloning?() :: boolean()
  def cloning?, do: is_binary(get().reference_audio)

  # ---------------------------------------------------------------------------

  defp validate(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case validate_one(to_string(key), raw) do
        {:ok, k, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        :skip -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_one("device", raw) do
    case blank(raw) do
      nil ->
        {:ok, :device, nil}

      "cuda:" <> n = v when n != "" ->
        if Integer.parse(n) != :error, do: {:ok, :device, v}, else: {:error, {:device, v}}

      v when v in @devices ->
        {:ok, :device, v}

      v ->
        {:error, {:device, v}}
    end
  end

  defp validate_one("reference_audio", raw) do
    case blank(raw) do
      nil ->
        {:ok, :reference_audio, nil}

      path ->
        if File.regular?(Path.expand(path)),
          do: {:ok, :reference_audio, Path.expand(path)},
          else: {:error, {:reference_audio, :not_found}}
    end
  end

  defp validate_one("control", raw), do: {:ok, :control, blank(raw)}

  defp validate_one("inference_timesteps", raw) do
    case blank(raw) do
      nil -> {:ok, :inference_timesteps, nil}
      v -> positive_int(v, :inference_timesteps)
    end
  end

  defp validate_one("cfg_value", raw) do
    case blank(raw) do
      nil ->
        {:ok, :cfg_value, nil}

      v ->
        case Float.parse(v) do
          {f, ""} when f > 0 -> {:ok, :cfg_value, f}
          _ -> {:error, {:cfg_value, v}}
        end
    end
  end

  defp validate_one("engine_path", raw) do
    case blank(raw) do
      nil -> {:ok, :engine_path, nil}
      path -> {:ok, :engine_path, Path.expand(path)}
    end
  end

  defp validate_one(_unknown, _raw), do: :skip

  defp positive_int(v, key) do
    case Integer.parse(v) do
      {i, ""} when i > 0 -> {:ok, key, i}
      _ -> {:error, {key, v}}
    end
  end

  defp blank(nil), do: nil

  defp blank(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp compact(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> %{}
  end
end
