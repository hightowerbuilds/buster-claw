defmodule BusterClaw.Commands.Catalog.Extensions do
  @moduledoc """
  Catalog entries: extensions — the after-download capability layer.

  The tiering here encodes one rule from `EXTENSIONS_ROADMAP.md` (D3): an
  extension may **tighten** but never **loosen**.

  - `extension_enable` turns on a declared set of tools, hosts, and write verbs.
    It is the consent moment, so it is **gated** — an agent may ask for it, and a
    person answers.
  - `extension_disable` only ever removes capability, so it is not gated.
    Requiring approval to make something safer is how a kill switch ends up
    unreachable in the moment it is needed.
  - `extension_add_part` writes a **disabled** part and cannot touch a manifest,
    so it can add no capability at all. It is `:restricted` because it writes a
    durable instruction into the workspace, not because of what it can reach.
  """

  @doc "Extension catalog entries."
  def entries,
    do: [
      %{
        name: "extension_list",
        type: :read,
        tier: :safe,
        description:
          "Installed extensions: what each one is, what it may reach (hosts, write verbs, whether it touches money), and whether it is switched on.",
        args: %{}
      },
      %{
        name: "extension_show",
        type: :read,
        tier: :safe,
        description:
          "One extension's manifest and parts — its declared reach and the playbooks it ships.",
        args: %{"id" => %{type: :string, required: true}}
      },
      %{
        name: "extension_add_part",
        type: :mutate,
        tier: :restricted,
        description:
          "Attach a part (a reference playbook, or a composition of existing commands) to an installed extension. The part is always written DISABLED — an operator enables it after reading. Cannot change a manifest, so it can never widen what the extension reaches.",
        args: %{
          "id" => %{type: :string, required: true},
          "name" => %{type: :string, required: true, description: "Part name, [a-z0-9-]."},
          "body" => %{type: :string, required: true, description: "The playbook markdown."},
          "description" => %{
            type: :string,
            required: false,
            description: "One line, shown on the enable screen."
          },
          "kind" => %{type: :string, required: false, enum: ["reference", "composition"]},
          "steps" => %{
            type: :array,
            required: false,
            description: "Composition only: ordered {command, args} steps."
          }
        }
      },
      %{
        name: "extension_enable",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description:
          "Switch an extension on, granting the tools, hosts, and write verbs its manifest declares. Gated: this is the consent moment.",
        args: %{"id" => %{type: :string, required: true}}
      },
      %{
        name: "extension_disable",
        type: :mutate,
        tier: :restricted,
        description:
          "Switch an extension off. Its parts leave the skills surface immediately. Not gated — removing capability never needs approval.",
        args: %{"id" => %{type: :string, required: true}}
      }
    ]
end
