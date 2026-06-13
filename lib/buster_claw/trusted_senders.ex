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

  # Anchored variants used to validate a single user-entered entry.
  @anchored_address ~r/^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/
  @anchored_wildcard ~r/^\*@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})$/
  @anchored_domain ~r/^[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/

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

  @doc """
  The configured allow-entries as `%{type: :address | :domain, value: ...}` —
  addresses first (alphabetical), then domain rules. Domain entries are rendered
  in their `*@domain` wildcard form.
  """
  def list_entries do
    contents = read_policy_contents()

    addresses =
      contents |> scan_addresses() |> Enum.sort() |> Enum.map(&%{type: :address, value: &1})

    domains =
      contents |> scan_domains() |> Enum.sort() |> Enum.map(&%{type: :domain, value: "*" <> &1})

    # People first, then domain rules — each alphabetical.
    addresses ++ domains
  end

  @doc """
  Add an allow-entry. Accepts a full address (`alice@example.com`), a wildcard
  (`*@example.com`), or a bare domain (`example.com`, treated as the wildcard).
  Idempotent. Returns `{:ok, normalized_value}` or `{:error, :invalid_entry}`.
  """
  def add_entry(raw) do
    case normalize_entry(raw) do
      {:ok, entry} ->
        contents = read_or_seed()

        if entry_present?(contents, entry) do
          {:ok, entry.value}
        else
          with :ok <-
                 File.write(
                   policy_path(),
                   ensure_trailing_newline(contents) <> "- #{entry.value}\n"
                 ) do
            {:ok, entry.value}
          end
        end

      :error ->
        {:error, :invalid_entry}
    end
  end

  @doc """
  Remove an allow-entry (any form that normalizes to the same address/domain).
  Returns `:ok` (a no-op if it was not present) or `{:error, :invalid_entry}`.
  """
  def remove_entry(raw) do
    case normalize_entry(raw) do
      {:ok, entry} ->
        updated =
          read_or_seed()
          |> String.split("\n")
          |> Enum.reject(&line_matches_entry?(&1, entry))
          |> Enum.join("\n")

        File.write(policy_path(), updated)

      :error ->
        {:error, :invalid_entry}
    end
  end

  # Normalize a user entry into %{type, value, key}. `value` is the canonical form
  # written to / shown from the file; `key` matches the parser's internal form.
  defp normalize_entry(raw) do
    value = raw |> to_string() |> String.trim() |> String.downcase()

    cond do
      Regex.match?(@anchored_address, value) ->
        {:ok, %{type: :address, value: value, key: value}}

      match = Regex.run(@anchored_wildcard, value) ->
        [_, domain] = match
        {:ok, %{type: :domain, value: "*@" <> domain, key: "@" <> domain}}

      Regex.match?(@anchored_domain, value) ->
        {:ok, %{type: :domain, value: "*@" <> value, key: "@" <> value}}

      true ->
        :error
    end
  end

  defp entry_present?(contents, %{type: :address, key: key}), do: key in scan_addresses(contents)
  defp entry_present?(contents, %{type: :domain, key: key}), do: key in scan_domains(contents)

  defp line_matches_entry?(line, %{type: :address, key: key}), do: key in scan_addresses(line)
  defp line_matches_entry?(line, %{type: :domain, key: key}), do: key in scan_domains(line)

  defp read_policy_contents do
    case File.read(policy_path()) do
      {:ok, contents} -> contents
      _ -> ""
    end
  end

  defp read_or_seed do
    case File.read(policy_path()) do
      {:ok, contents} ->
        contents

      _ ->
        File.mkdir_p!(Path.dirname(policy_path()))
        header = "# Trusted email senders\n\n"
        File.write!(policy_path(), header)
        header
    end
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(contents) do
    if String.ends_with?(contents, "\n"), do: contents, else: contents <> "\n"
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
