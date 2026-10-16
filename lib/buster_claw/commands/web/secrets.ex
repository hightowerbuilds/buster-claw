defmodule BusterClaw.Commands.Web.Secrets do
  @moduledoc "The fences an operator sets once — `browser_secret_*` and `browser_egress_level`."
  # Split out of `BusterClaw.Commands.Web` on 10-16 (CODE_QUALITY_SWEEP Phase
  # 6); that module is the facade and the catalog's door.

  alias BusterClaw.BrowserControl.Egress.Policy
  alias BusterClaw.BrowserControl.Secrets

  @doc """
  Read or set how much page content may leave the machine, per host.

  With no `host`, lists the levels in force — shipped defaults plus the
  operator's entries layered over them. With `host` and `level`, records one
  (`full` | `structure_only` | `never`); `level: null` removes it and returns
  the host to the default.

  This exists because the mechanism was unreachable: `Policy.level_for/2` has
  always taken `:overrides`, and `AgentMode` called `Egress.prepare/2` with no
  opts, so nothing could ever feed it. The 07-25 field test measured 89.8 KB
  leaving over 41 steps, every one at `:full` with zero redactions.

  A level applies to the host **and its subdomains**, most specific wins, and
  ties break toward the stricter level. Runs freeze these at start, so a change
  takes effect on the next run rather than mid-errand.
  """
  def browser_egress_level(args \\ %{})

  def browser_egress_level(%{"host" => host} = args) when is_binary(host) and host != "" do
    with {:ok, entries} <- Policy.put_override(host, Map.get(args, "level")) do
      {:ok, %{host: host, level: Map.get(args, "level"), overrides: shape_levels(entries)}}
    end
  end

  def browser_egress_level(_args) do
    {:ok,
     %{
       in_force: shape_levels(Policy.overrides()),
       operator_set: shape_levels(Policy.stored_overrides()),
       default: "full",
       levels: Enum.map(Policy.levels(), &Atom.to_string/1)
     }}
  end

  defp shape_levels(entries) do
    Enum.map(entries, fn {host, level} -> %{host: host, level: Atom.to_string(level)} end)
  end

  @doc """
  Store a value an Agent Mode run may type as `$secret.<name>` without ever
  reading it. Encrypted at rest; replaces an existing name.

  This is the store that never existed behind `SecretRef` — until 08-03 every
  `$secret.<name>` failed, so no unattended run could sign in anywhere.
  """
  def browser_secret_put(%{"name" => name, "value" => value} = args)
      when is_binary(name) and is_binary(value) do
    Secrets.put(name, value, Map.get(args, "note"))
  end

  def browser_secret_put(_args), do: {:error, :missing_name_or_value}

  @doc """
  The stored secret **names**, with notes and when they changed — never values.

  There is deliberately no command that returns a value, and there must never be
  one: the reference design exists so a model can drive a form it cannot read.
  """
  def browser_secret_list(_args \\ %{}) do
    secrets = Secrets.names()
    {:ok, %{secrets: secrets, count: length(secrets)}}
  end

  @doc "Forget a stored secret. Unknown names say so rather than passing quietly."
  def browser_secret_delete(%{"name" => name}) when is_binary(name) and name != "" do
    Secrets.delete(name)
  end

  def browser_secret_delete(_args), do: {:error, :missing_name}
end
