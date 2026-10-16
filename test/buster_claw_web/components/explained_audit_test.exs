defmodule BusterClawWeb.ExplainedAuditTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BusterClaw.Commands
  alias BusterClawWeb.ExplainedPanel

  test "every tutorial link reaches a current route or an anchor on that page" do
    for tab <- ExplainedPanel.tab_keys() do
      document = document(tab)
      links = document |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")

      for href <- links do
        case URI.parse(href) do
          %URI{path: nil, fragment: fragment} when is_binary(fragment) ->
            refute Enum.empty?(LazyHTML.query_by_id(document, fragment)),
                   "#{tab} links to missing anchor #{href}"

          %URI{scheme: nil, path: path} ->
            refute path in ~w(/voice /cmd-list /sketch),
                   "#{tab} links to a retired surface: #{href}"

            assert Phoenix.Router.route_info(BusterClawWeb.Router, "GET", path, "localhost") !=
                     :error,
                   "#{tab} links to missing route #{href}"

          _external ->
            :ok
        end
      end
    end
  end

  test "commands shown by tutorials belong to the current catalog" do
    names = Commands.list_commands() |> Enum.map(& &1.name) |> MapSet.new()
    families = names |> Enum.map(&hd(String.split(&1, "_"))) |> MapSet.new()
    families = MapSet.union(families, MapSet.new(~w(voice sketch trading)))

    for tab <- ExplainedPanel.tab_keys() do
      commands =
        tab
        |> document()
        |> LazyHTML.query("code")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
        |> Enum.filter(fn command ->
          Regex.match?(~r/^[a-z]+(?:_[a-z0-9]+)+$/, command) and
            MapSet.member?(families, hd(String.split(command, "_")))
        end)

      for command <- commands do
        assert MapSet.member?(names, command), "#{tab} teaches a missing command: #{command}"
      end
    end
  end

  # Every removal so far — trading, the Sketch Pad, the cut-up, VoxCPM, the
  # phone — took its own tab or verbs and left the OTHER tabs' sentences
  # standing; and the app's geography (dock → sidebar, sub-tabs → panels, the
  # corner widget → the Clock panel) changed under prose nothing re-read. The
  # command and route guards above cannot see a sentence. This list can
  # (EXPLAINED_REWRITE D7): add the phrase the next removal leaves behind.
  test "rendered tutorials do not promise retired features or name places that moved" do
    for tab <- ExplainedPanel.tab_keys() do
      text = tab |> document() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

      for stale <- [
            "VoxCPM",
            "Vox2B",
            "voice cloned from yours",
            "Voice Library",
            "Sketch Pad",
            "a broker",
            "Phone tab",
            "phone line",
            "phone number",
            "voicemail",
            "shaderface",
            "contact-faces",
            "the dock",
            "sub-tab",
            "corner widget",
            "Workspace page's"
          ] do
        refute text =~ stale, "#{tab} still describes retired functionality: #{stale}"
      end
    end
  end

  defp document(tab) do
    render_component(&ExplainedPanel.explained_panel/1, tab: tab)
    |> LazyHTML.from_fragment()
  end
end
