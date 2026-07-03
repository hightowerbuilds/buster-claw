defmodule BusterClaw.Commands.Catalog do
  @moduledoc """
  The native command catalog: a pure, constant list of command metadata
  (`name`, `type`, `tier`, gating, arg schema, `description`).

  Split out of `BusterClaw.Commands` so the facade carries dispatch/policy logic
  while the catalog carries the large, declarative data. The entries themselves
  live in per-domain modules under `BusterClaw.Commands.Catalog.*` (Library,
  Integrations, Wallets, Google, …); `entries/0` concatenates them in the
  original catalog order. `entries/0` is rebuilt on each call;
  `BusterClaw.Commands` memoizes it in `:persistent_term`, so this stays a
  plain function (a module attribute can't call local functions at compile
  time, which is why the catalog is assembled at runtime).
  """

  alias BusterClaw.Commands.Catalog.{
    Finance,
    Google,
    GoogleContacts,
    GoogleFiles,
    Integrations,
    Library,
    Orchestration,
    Wallets,
    Web
  }

  @doc "Return the native command catalog as a list of metadata maps."
  def entries,
    do:
      Library.entries() ++
        Integrations.entries() ++
        Wallets.entries() ++
        Google.entries() ++
        GoogleFiles.entries() ++
        GoogleContacts.entries() ++
        Web.entries() ++
        Finance.entries() ++
        Orchestration.entries()
end
