defmodule BusterClawWeb.FormSubmitTest do
  @moduledoc """
  A form with `phx-change`, a text input, and no `phx-submit` is submitted
  **natively** by the browser when the operator presses Enter.

  That navigates the page. LiveView remounts, every assign returns to its mount
  default, and whatever was being typed is gone. In the packaged app on 08-15 it
  read as *"the Studio's Voice tab closes and throws me back to Chat"* — nothing
  crashed, the page had simply been replaced (`DMG-review-8-15`, finding 3).

  ## Why the suite could not already see this

  Every LiveView test in this repo drives forms with `render_change/2` or
  `render_submit/2`, which push the event straight at the process. **Neither can
  produce a native submit**, because neither involves a browser. So this whole
  category is invisible to `LiveViewTest` by construction, and a source check is
  the only instrument that reaches it — the same argument
  `hooks_registered_test.exs` makes about `phx-hook`.

  ## Why the check is narrowed to text inputs

  HTML implicit submission needs a field that supports it. A form of selects and
  checkboxes does not submit on Enter, and twelve of this app's forms are exactly
  that — the appearance pickers, the settings toggles, the studio sidebar. Failing
  those would be noise, and noise is how a guard gets deleted. So the rule is the
  one that actually bites: **`phx-change` + a text-like input + no `phx-submit`.**

  Measured when this was written: 57 form tags in the web layer, 14 with
  `phx-change` and no `phx-submit`, of which **3** carried a text input. All
  three now have one.

  The third was the Notes ⌘P switcher, and it is the interesting case: its hook
  already claimed Enter with `preventDefault()`, so it was safe *while the hook
  was attached*. That is a real qualifier — a click landing before LiveView
  connects is silently discarded in this app, which is filed separately, and the
  same window leaves Enter to the browser. `phx-submit` is the floor under the
  hook rather than a replacement for it.

  So the rule this test enforces is deliberately the stricter one: **the server
  must own Enter, not the JS.** A hook may still claim it for better behaviour;
  it may not be the only thing standing between a keystroke and a lost page.
  """
  use ExUnit.Case, async: true

  @web Path.wildcard("lib/buster_claw_web/**/*.ex")

  # `<form …>` or `<.form …>` up to the closing angle bracket, across newlines —
  # these tags are routinely eight attributes tall in a `~H` block.
  @form_tag ~r/<\.?form\b[^>]*>/s

  # What HTML calls "a field that supports implicit submission". `<input>` with
  # no type at all defaults to text, so a bare `<input` counts too.
  @text_input ~r/type="(?:text|search|email|url|tel|number|password)"|<textarea|<input(?![^>]*type=)/s

  test "no form can be submitted natively by pressing Enter" do
    offenders =
      for path <- @web,
          source = File.read!(path),
          [tag] <- Regex.scan(@form_tag, source),
          String.contains?(tag, "phx-change"),
          not String.contains?(tag, "phx-submit"),
          body = form_body(source, tag),
          Regex.match?(@text_input, body) do
        line = source |> String.split(tag) |> hd() |> String.split("\n") |> length()
        "  #{path}:#{line}"
      end

    assert offenders == [],
           """
           These forms carry `phx-change` and a text input but no `phx-submit`, so
           pressing Enter in them submits the form NATIVELY: the page navigates,
           the LiveView remounts, and the operator loses what they were typing.

           #{Enum.join(offenders, "\n")}

           Fix by adding `phx-submit` (re-using the change handler is fine — the
           point is that LiveView handles the event instead of the browser), or by
           claiming Enter in a hook with `preventDefault()`, which is what the
           Notes ⌘P switcher does.
           """
  end

  # From the end of the opening tag to `</form>`. A `<.form>` component closes
  # with `</.form>`, so both are accepted; an unclosed match falls back to a
  # generous window rather than swallowing the rest of the file.
  defp form_body(source, tag) do
    case String.split(source, tag, parts: 2) do
      [_before, rest] ->
        case String.split(rest, ~r{</\.?form>}, parts: 2) do
          [body, _after] -> body
          [_only] -> String.slice(rest, 0, 2_000)
        end

      _ ->
        ""
    end
  end
end
