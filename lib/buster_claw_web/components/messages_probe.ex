defmodule BusterClawWeb.MessagesProbe do
  @moduledoc "The explicit packaged-app readiness check; it never fetches message bodies."
  use BusterClawWeb, :html

  attr :result, :any, required: true

  def panel(assigns) do
    ~H"""
    <section id="messages-probe" class="ic-panel space-y-4 p-6">
      <h2 class="ic-eyebrow">iMessage connection</h2>
      <p class="text-sm text-base-content/70">
        Check whether this app can access Messages on your Mac. Text reception and replies
        are still being built. Twilio continues to handle voicemail.
      </p>
      <button
        id="messages-probe-button"
        type="button"
        phx-click="probe_messages"
        disabled={@result == :checking}
        class="ic-btn transition-opacity disabled:opacity-50"
      >
        {if @result == :checking, do: "Checking…", else: "Check iMessage access"}
      </button>
      <p id="messages-probe-result" role="status" class="text-sm text-base-content/80">
        {message(@result)}
      </p>
    </section>
    """
  end

  defp message(nil), do: "Not checked. This check does not read conversations or send messages."
  defp message(:checking), do: "Checking access…"

  defp message({:ok, %{state: :read_ready}}),
    do: "Messages database access is available. Sending permission has not been tested."

  defp message({:ok, %{state: :database_unavailable}}),
    do:
      "Messages could not be opened. Check that Messages is set up and review Full Disk Access in macOS System Settings → Privacy & Security, then restart the app and check again."

  defp message({:error, :not_installed}), do: "The Messages adapter is missing from this build."

  defp message({:error, :unsupported_version}),
    do: "The Messages adapter version does not match this build."

  defp message(_), do: "The Messages check could not finish. Try again."
end
