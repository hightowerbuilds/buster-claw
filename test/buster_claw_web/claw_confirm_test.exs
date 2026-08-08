defmodule BusterClawWeb.ClawConfirmTest do
  @moduledoc """
  Guards against reintroducing a **native confirmation dialog** anywhere in the
  app.

  `window.confirm()` gates on a synchronous native dialog, and there is no
  WKUIDelegate in the Tauri/WKWebView shell to service one — so it is a no-op
  that returns `false`. Every confirm-gated action therefore silently never
  fires. Destructive controls must use `data-claw-confirm`, serviced by the
  interceptor in `assets/js/lib/claw_confirm.js`.

  ## Why this file grew a second spelling (08-08-26)

  It used to check one string, `data-confirm=`, in one directory. That is
  LiveView's native gate and only one of the ways to summon the dialog. The
  in-app browser's history page said `onsubmit="return confirm('…')"` instead,
  in a controller heredoc — a different spelling in a file this test read but a
  pattern it did not look for. **Both of its clear buttons were dead in the
  packaged app for months**, working perfectly in every dev browser, because
  `false` cancels the submit.

  So it now looks for the dialog itself, in `assets/js` as well as `lib`.

  ## Comments and docstrings are skipped, deliberately

  Six places in this repo *describe* this bug — including the paragraph above.
  A guard that flags its own explanation is a guard someone deletes, so
  `code_lines/1` drops `#` / `//` comments and `\"\"\"` heredocs before matching.
  The tradeoff is that a violation hidden inside a heredoc is invisible here;
  for the four in-app browser pages, `browser_page_headers_test.exs` closes that
  by asserting on **rendered output**, which no comment can fool.
  """
  use ExUnit.Case, async: true

  @web_dir Path.expand("../../lib/buster_claw_web", __DIR__)
  @js_dir Path.expand("../../assets/js", __DIR__)

  # An inline event-handler attribute (onclick=, onsubmit=, …) whose value calls
  # confirm(). This is the spelling that got through.
  @inline_handler ~r/on[a-z]+\s*=\s*["'][^"']*\bconfirm\s*\(/

  # A native confirm call in JS: `confirm(...)` or `window.confirm(...)`, but not
  # `clawConfirm(` — the capital C is what distinguishes ours from theirs.
  @native_call ~r/(?<![a-zA-Z.])confirm\s*\(|window\s*\.\s*confirm\s*\(/

  describe "the native confirm dialog is unreachable" do
    test "no template uses LiveView's data-confirm gate" do
      offenders = scan(elixir_files(), ~r/data-confirm=/)

      assert offenders == [],
             """
             These use `data-confirm=`, which does nothing in the webview
             (window.confirm returns false). Switch to `data-claw-confirm=`:

             #{format(offenders)}
             """
    end

    test "no template carries an inline handler that calls confirm()" do
      offenders = scan(elixir_files(), @inline_handler)

      assert offenders == [],
             """
             These carry an inline `on…="… confirm(…)"` handler. In the webview
             `confirm()` returns false, so `return confirm(…)` CANCELS the
             action — the control looks fine and does nothing. This is exactly
             how the browser history page's clear buttons stayed dead.

             Use `data-claw-confirm` and the shared interceptor:

             #{format(offenders)}
             """
    end

    test "no JavaScript calls the native confirm" do
      offenders = scan(js_files(), @native_call)

      assert offenders == [],
             """
             These call the native `confirm()`, which returns false in the
             webview. Use `clawConfirm(message)` from
             `assets/js/lib/claw_confirm.js`, which resolves a real modal:

             #{format(offenders)}
             """
    end
  end

  test "the confirm interceptor is installed at app boot" do
    assert File.read!(Path.join(@js_dir, "app.js")) =~ "installClawConfirm()"
  end

  test "the in-app browser pages install it too" do
    # They are plain controller HTML, not LiveView, so they never load app.js —
    # their bundle has to install the interceptor itself.
    assert File.read!(Path.join(@js_dir, "browser_pages.js")) =~ "installClawConfirm()"
  end

  # --- scanning ---------------------------------------------------------------

  defp elixir_files, do: @web_dir |> Path.join("**/*.ex") |> Path.wildcard()

  defp js_files do
    @js_dir
    |> Path.join("**/*.js")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".test.js"))
  end

  defp format(offenders), do: Enum.map_join(offenders, "\n", &"  - #{&1}")

  defp scan(files, pattern) do
    for file <- files,
        {line, number} <- code_lines(File.read!(file)),
        Regex.match?(pattern, line),
        do: "#{Path.relative_to(file, File.cwd!())}:#{number}"
  end

  # Source lines with comments and DOC heredocs removed, keeping original line
  # numbers.
  #
  # Only `@moduledoc` / `@doc` heredocs are skipped — emphatically not every
  # heredoc, because **a `~H` template is a heredoc** and skipping those would
  # have blinded this test to every LiveView and function component in the app.
  # That was the first version's bug, caught by feeding it the real historical
  # defect: it passed, because the defect lived inside `~H"""`.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, number}, {kept, in_doc?} ->
      trimmed = String.trim_leading(line)

      cond do
        in_doc? ->
          {kept, not String.starts_with?(trimmed, ~s("""))}

        Regex.match?(~r/@(module|short)?doc\s+(~[A-Za-z])?"""/, line) ->
          {kept, true}

        String.starts_with?(trimmed, ["#", "//", "*"]) ->
          {kept, false}

        true ->
          {[{line, number} | kept], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
