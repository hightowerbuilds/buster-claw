defmodule BusterClaw.BrowserControl.Egress.SecretRef do
  @moduledoc """
  Secret references (BROWSER_ENGINE_ROADMAP Phase 3.5, part 1) — the
  highest-leverage mitigation and the most buildable.

  The model never emits a secret value. It emits a **reference** —
  `$secret.shipping_address` — and Buster Claw resolves it locally, in the
  executor, at the moment of the action. Credentials, addresses, phone numbers,
  and card data therefore pass through the executor and never through the
  reasoner: the model can drive a checkout it is constitutionally incapable of
  reading.

  Two directions:

    * `resolve/2` swaps references for real values just before a `fill`/`type`
      reaches the browser. The resolver is injected (`fn name -> {:ok, v} |
      :error end`) so the secret store — Keychain, wallet, encrypted settings —
      stays out of this pure module.
    * `mask/1` produces the **log-safe** form: the reference token survives, the
      value never appears. The trajectory records `$secret.shipping_address`,
      never its expansion — so "what the model saw" and "what we logged" are both
      value-free by construction.

  A reference to a name the store doesn't know is `{:error, {:unknown_secret,
  name}}` — a resolve failure, never a silent empty string typed into a field.
  """

  # $secret.<name> where <name> is a dotted/underscored/hyphenated identifier.
  @ref_re ~r/\$secret\.([a-zA-Z0-9_.-]+)/

  @doc "List the secret names referenced in `text` (no resolution, for accounting)."
  def references(text) when is_binary(text) do
    Regex.scan(@ref_re, text) |> Enum.map(fn [_, name] -> name end) |> Enum.uniq()
  end

  def references(_), do: []

  @doc "True if `text` contains at least one secret reference."
  def ref?(text) when is_binary(text), do: Regex.match?(@ref_re, text)
  def ref?(_), do: false

  @doc """
  Resolve every reference in `text` via `resolver` (`fn name -> {:ok, value} |
  :error end`). Returns `{:ok, resolved_text}` or, on the first unknown name,
  `{:error, {:unknown_secret, name}}` — the whole resolution fails rather than
  half-filling a form.
  """
  def resolve(text, resolver) when is_binary(text) and is_function(resolver, 1) do
    Enum.reduce_while(references(text), {:ok, text}, fn name, {:ok, acc} ->
      case resolver.(name) do
        {:ok, value} when is_binary(value) ->
          {:cont, {:ok, String.replace(acc, "$secret." <> name, value)}}

        _ ->
          {:halt, {:error, {:unknown_secret, name}}}
      end
    end)
  end

  def resolve(other, _resolver), do: {:ok, other}

  @doc """
  Log-safe rendering: each `$secret.<name>` becomes `⟨secret:<name>⟩`. Applied to
  anything bound for the trajectory or the model, so a resolved value can never
  leak through the audit path.
  """
  def mask(text) when is_binary(text) do
    Regex.replace(@ref_re, text, fn _, name -> "⟨secret:#{name}⟩" end)
  end

  def mask(other), do: other
end
