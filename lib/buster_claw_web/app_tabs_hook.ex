defmodule BusterClawWeb.AppTabsHook do
  @moduledoc "Connects only a mounted top-level tab strip to app layout commands."
  import Phoenix.LiveView
  alias BusterClaw.AppTabs

  def on_mount(:default, _params, session, socket) do
    if session["embedded"] == true do
      {:cont, socket}
    else
      {:cont,
       socket
       |> attach_hook(:app_tabs, :handle_info, &handle_info/2)
       |> attach_hook(:app_tabs, :handle_event, &handle_event/3)}
    end
  end

  defp handle_info({:app_tabs, request}, socket),
    do: {:halt, push_event(socket, "bc:app_tabs", request)}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("bc:tabs_ready", _params, socket) do
    AppTabs.register()
    {:halt, socket}
  end

  defp handle_event("bc:tabs_result", %{"ref" => ref, "result" => result}, socket) do
    result =
      case result do
        %{"error" => error} when is_binary(error) -> {:error, error}
        %{"value" => value} when is_map(value) -> {:ok, value}
        _ -> {:error, :invalid_tab_result}
      end

    accepted = AppTabs.fulfill(ref, result)
    {:halt, %{accepted: accepted}, socket}
  end

  defp handle_event("bc:tabs_notice", %{"error" => error}, socket),
    do: {:halt, put_flash(socket, :error, error)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
