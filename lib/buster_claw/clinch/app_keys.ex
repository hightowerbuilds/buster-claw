defmodule BusterClaw.Clinch.AppKeys do
  @moduledoc """
  The app's own service credentials — Twilio, the Supabase relay, Finnhub — and
  the one place that answers "what is this value right now?".

  ## Why this exists

  These lived in `runtime.exs`, read from environment variables. That has two
  defects a packaged app cannot work around:

  1. **A double-clicked `.app` inherits launchd's environment, not your shell's.**
     Credentials exported in `.zshrc` are simply invisible to the shipped product,
     which is why BusterPhone has never been configurable outside a dev terminal.
  2. **An environment variable cannot be rotated or revoked** from inside the app.
     There is no "replace this key" and no "this key is compromised, stop using
     it" — only "edit a file and restart".

  Both close by moving the values into the Clinch as `:app_key` credentials.

  ## Read live, never at boot

  `Application.get_env/2` is resolved when the app starts. A credential typed into
  a settings screen after boot would be invisible to it forever, so every reader
  here goes through `get/1` **at the moment of use** instead of caching a value.

  That is also what makes revocation real: delete the row and the next call
  returns `nil`, with no process holding a stale copy.

  ## Clinch first, environment second

  `get/1` prefers a stored credential and falls back to the environment, so dev
  and CI keep working unchanged while a packaged app can be configured from the
  UI. The fallback is deliberately not removed — CI has no UI to type into.

  ## These reads are not audited, and that is deliberate

  `Clinch.resolve/2` records a use, because the audit feed's question is *who used
  a credential*. A poller reading its own configuration every 30 seconds is not
  that question, and letting it answer would bury the events that matter under
  thousands that do not. Resolution here passes `audit: false`; **agent use of a
  `$secret` remains fully audited**, which is the case the feed exists for.

  ## What stays an environment variable on purpose

  `BUSTER_CLAW_SMS_ENABLED` is a kill switch, not a credential. It stays outside
  the Clinch precisely because it should be awkward to flip — a switch you can
  turn on from a settings screen is not the same safeguard as one that needs a
  deliberate act outside the running app.
  """

  alias BusterClaw.Clinch

  # One list feeding the resolver and (Phase 3d) the settings screen. Adding a
  # credential is a row here and nothing else.
  #
  # `env` is named for display only — the screen says where a value is coming
  # from today, so "it works in my terminal but not in the app" becomes visible
  # rather than mysterious.
  @keys [
    %{
      name: "twilio_account_sid",
      label: "Twilio Account SID",
      env: "TWILIO_ACCOUNT_SID",
      group: "BusterPhone",
      secret?: false,
      note: "Identifies the Twilio account. Not secret, but required to place calls."
    },
    %{
      name: "twilio_auth_token",
      label: "Twilio Auth Token",
      env: "TWILIO_AUTH_TOKEN",
      group: "BusterPhone",
      secret?: true,
      note: "Full control of the Twilio account. Rotate from the Twilio console."
    },
    %{
      name: "twilio_messaging_service_sid",
      label: "Twilio Messaging Service SID",
      env: "TWILIO_MESSAGING_SERVICE_SID",
      group: "BusterPhone",
      secret?: false,
      note: "Required for outbound SMS, which additionally needs the env kill switch."
    },
    # Outbound VOICE needs both of these and outbound SMS needs neither, which is
    # why they arrive together and late. A message is addressed by Messaging
    # Service; a call needs an explicit `From`, and the bridge needs to know
    # which phone to ring first.
    %{
      name: "twilio_phone_number",
      label: "Twilio Phone Number",
      env: "TWILIO_PHONE_NUMBER",
      group: "BusterPhone",
      secret?: false,
      note:
        "E.164, e.g. +13603646763. The number a call comes FROM — so a person " <>
          "who calls it back reaches the answering machine, not you."
    },
    %{
      name: "operator_phone_number",
      label: "Your Phone Number",
      env: "OPERATOR_PHONE_NUMBER",
      group: "BusterPhone",
      secret?: false,
      note:
        "E.164. Outbound calls ring THIS phone first, then dial the other party " <>
          "and bridge you — so no audio ever passes through this app."
    },
    %{
      name: "supabase_url",
      label: "Supabase URL",
      env: "SUPABASE_URL",
      group: "BusterPhone",
      secret?: false,
      note: "The relay project. Stored beside its key so the pair is configured together."
    },
    %{
      name: "supabase_service_role_key",
      label: "Supabase service-role key",
      env: "SUPABASE_SERVICE_ROLE_KEY",
      group: "BusterPhone",
      secret?: true,
      note: "Bypasses RLS entirely — the most powerful credential in the relay project."
    },
    %{
      name: "finnhub_api_key",
      label: "Finnhub API key",
      env: "FINNHUB_API_KEY",
      group: "Finance",
      secret?: true,
      note: "Optional. Without it finance_quote / finance_news report not_configured."
    }
  ]

  @names Enum.map(@keys, & &1.name)

  @doc "Every app key, in display order."
  @spec all() :: [map()]
  def all, do: @keys

  @doc "The names this module knows. A name outside it is a typo, not a credential."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "One key's definition, or `nil`."
  @spec definition(String.t()) :: map() | nil
  def definition(name), do: Enum.find(@keys, &(&1.name == name))

  @doc """
  The current value: the Clinch's stored credential, else the environment, else
  `nil`.

  Read at the moment of use — never cached, never resolved at boot.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(name) when is_binary(name) do
    case Clinch.resolve({:app_key, name}, audit: false) do
      {:ok, value} -> value
      :error -> from_env(name)
    end
  end

  @doc """
  Where a value is coming from right now — `:clinch`, `:env`, or `:unset`.

  The settings screen shows this so "configured" and "configured *here*" are
  distinguishable, and so an operator can tell that the packaged app is not seeing
  the variable their terminal does.
  """
  @spec source(String.t()) :: :clinch | :env | :unset
  def source(name) when is_binary(name) do
    cond do
      match?({:ok, _}, Clinch.resolve({:app_key, name}, audit: false)) -> :clinch
      present?(from_env(name)) -> :env
      true -> :unset
    end
  end

  # The environment fallback reads the same `Application` values `runtime.exs`
  # populated, rather than `System.get_env/1` — so a release configured the old
  # way keeps working, and tests that set app env keep controlling these.
  defp from_env("twilio_account_sid"), do: twilio(:account_sid)
  defp from_env("twilio_auth_token"), do: twilio(:auth_token)
  defp from_env("twilio_messaging_service_sid"), do: twilio(:messaging_service_sid)
  defp from_env("twilio_phone_number"), do: twilio(:phone_number)
  defp from_env("operator_phone_number"), do: twilio(:operator_number)
  defp from_env("supabase_url"), do: app_env(:telephony_relay_url)
  defp from_env("supabase_service_role_key"), do: app_env(:telephony_relay_key)
  defp from_env("finnhub_api_key"), do: app_env(:finnhub_api_key)
  defp from_env(_unknown), do: nil

  defp twilio(field) do
    :buster_claw
    |> Application.get_env(:twilio, %{})
    |> get_in([field])
    |> presence()
  end

  defp app_env(key), do: :buster_claw |> Application.get_env(key) |> presence()

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp presence(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
