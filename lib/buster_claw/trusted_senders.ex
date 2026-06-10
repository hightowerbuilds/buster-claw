defmodule BusterClaw.TrustedSenders do
  @moduledoc """
  Trusted-sender policy: decides whether an inbound email sender may drive
  follow-through work — i.e. be enqueued on the Dispatch queue. Untrusted senders
  are still archived to the Library; they just don't land on the agent's plate.

  The policy lives at `<workspace>/memory/trusted-email-senders.md`. It is freeform
  markdown; the parser pulls out allow-entries:

    - a full address — `alice@example.com`
    - a domain wildcard — `*@example.com` (trusts the whole domain)

  A missing or empty file means **no** sender is trusted (safe default).
  """
  alias BusterClaw.Library.Artifact

  @policy_file "trusted-email-senders.md"
  @address ~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
  @wildcard ~r/\*@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})/

  @doc "The matched allow-entry for `from`, or nil when the sender is untrusted."
  def match(from) do
    with address when is_binary(address) <- extract_address(from) do
      %{addresses: addresses, domains: domains} = load_policy()
      domain = "@" <> (address |> String.split("@") |> List.last())

      cond do
        address in addresses -> address
        domain in domains -> domain
        true -> nil
      end
    else
      _ -> nil
    end
  end

  @doc "Whether `from` may drive follow-through work."
  def trusted?(from), do: match(from) != nil

  @doc "Extract the bare lowercase address from a `Name <addr>` header."
  def extract_address(from) do
    case Regex.run(@address, to_string(from)) do
      [address | _] -> String.downcase(address)
      _ -> nil
    end
  end

  defp load_policy do
    case File.read(policy_path()) do
      {:ok, contents} ->
        %{addresses: scan_addresses(contents), domains: scan_domains(contents)}

      _ ->
        %{addresses: [], domains: []}
    end
  end

  defp scan_addresses(contents) do
    @address
    |> Regex.scan(contents)
    |> Enum.map(fn [address | _] -> String.downcase(address) end)
    |> Enum.uniq()
  end

  defp scan_domains(contents) do
    @wildcard
    |> Regex.scan(contents)
    |> Enum.map(fn [_full, domain] -> "@" <> String.downcase(domain) end)
    |> Enum.uniq()
  end

  defp policy_path do
    Path.join([Artifact.workspace_root(), "memory", @policy_file])
  end
end
