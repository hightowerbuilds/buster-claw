defmodule BusterClaw.Providers do
  @moduledoc "Local model provider configuration."

  import Ecto.Query

  alias BusterClaw.Provider.{Anthropic, Ollama, OpenAICompatible}
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Repo

  def list_providers, do: Repo.all(order_by(Provider, [p], asc: p.priority, asc: p.name))
  def get_provider!(id), do: Repo.get!(Provider, id)

  def create_provider(attrs) do
    attrs = apply_defaults(attrs)
    %Provider{} |> Provider.changeset(attrs) |> Repo.insert()
  end

  def update_provider(%Provider{} = provider, attrs),
    do: provider |> Provider.changeset(apply_defaults(attrs)) |> Repo.update()

  def delete_provider(%Provider{} = provider), do: Repo.delete(provider)

  def active_provider,
    do:
      Repo.one(from p in Provider, where: p.active == true, order_by: [asc: p.priority], limit: 1)

  def set_active_provider(%Provider{} = provider) do
    Repo.transaction(fn ->
      Repo.update_all(Provider, set: [active: false])
      provider |> Provider.changeset(%{active: true}) |> Repo.update!()
    end)
  end

  def test_provider(%Provider{} = provider), do: module_for(provider).test_connection(provider)

  def chat_with_active(messages, on_chunk) do
    case active_provider() do
      nil -> {:error, :no_active_provider}
      provider -> chat(provider, messages, on_chunk)
    end
  end

  def chat(%Provider{} = provider, messages, on_chunk) when is_function(on_chunk, 1) do
    module_for(provider).chat(provider, normalize_messages(messages), on_chunk)
  end

  defp module_for(%{type: "anthropic"}), do: Anthropic
  defp module_for(%{type: "ollama"}), do: Ollama
  defp module_for(_provider), do: OpenAICompatible

  defp normalize_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} -> %{role: role, content: content}
      %{"role" => role, "content" => content} -> %{role: role, content: content}
    end)
  end

  defp apply_defaults(attrs) do
    type = Map.get(attrs, :type) || Map.get(attrs, "type")
    base_url = Map.get(attrs, :base_url) || Map.get(attrs, "base_url")

    if base_url in [nil, ""] do
      put_default_base_url(attrs, type)
    else
      attrs
    end
  end

  defp put_default_base_url(attrs, "openrouter"),
    do: put_attr(attrs, :base_url, "https://openrouter.ai/api/v1")

  defp put_default_base_url(attrs, "openai"),
    do: put_attr(attrs, :base_url, "https://api.openai.com/v1")

  defp put_default_base_url(attrs, "anthropic"),
    do: put_attr(attrs, :base_url, "https://api.anthropic.com")

  defp put_default_base_url(attrs, "ollama"),
    do: put_attr(attrs, :base_url, "http://127.0.0.1:11434")

  defp put_default_base_url(attrs, _type), do: attrs

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1) do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, Atom.to_string(key), value)
    end
  end
end
