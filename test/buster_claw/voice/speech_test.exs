defmodule BusterClaw.Voice.SpeechTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Voice.Speech

  describe "code" do
    test "a fenced block is announced by language, and its contents never spoken" do
      spoken =
        Speech.to_spoken("""
        Here is the fix.

        ```elixir
        def handle_event("save", %{"id" => id}, socket) do
          {:noreply, assign(socket, :saved, id)}
        end
        ```

        That should do it.
        """)

      assert spoken =~ "elixir code block"
      assert spoken =~ "Here is the fix."
      assert spoken =~ "That should do it."

      # The actual point: none of the code survives into the utterance.
      refute spoken =~ "handle_event"
      refute spoken =~ ":noreply"
      refute spoken =~ "socket"
    end

    test "a fence with no language still says something" do
      assert Speech.to_spoken("Before\n\n```\nraw text\n```\n\nAfter") =~ "code block"
      refute Speech.to_spoken("Before\n\n```\nraw text\n```\n\nAfter") =~ "raw text"
    end

    test "an unterminated fence is handled, because a streamed reply can arrive mid-block" do
      spoken = Speech.to_spoken("Working on it.\n\n```python\nimport os\nos.remove(")

      assert spoken =~ "Working on it."
      assert spoken =~ "python code block"
      refute spoken =~ "import os"
    end

    test "inline code is spoken, because it is usually the identifier that matters" do
      assert Speech.to_spoken("Call `sound_apply` next.") == "Call sound_apply next."
    end

    test "a snake_case identifier is never mangled by emphasis rules" do
      # The bug this guards: `_var_` inside some_var_name looks exactly like
      # underscore emphasis, and stripping it says "somevarname".
      assert Speech.to_spoken("Use some_var_name here.") == "Use some_var_name here."
      assert Speech.to_spoken("`voice_greeting_set` is gated.") == "voice_greeting_set is gated."
    end
  end

  describe "links" do
    test "a markdown link speaks its label, not its target" do
      assert Speech.to_spoken("See [the pull request](https://example.com/a/b/c) for details.") ==
               "See the pull request for details."
    end

    test "a bare URL becomes its host, because path segments are unlistenable" do
      assert Speech.to_spoken("See https://example.com/owner/repo/pull/42 now.") ==
               "See a link to example.com now."
    end

    test "www is dropped" do
      assert Speech.to_spoken("Visit https://www.example.com/") == "Visit a link to example.com"
    end

    test "an image speaks its alt text" do
      assert Speech.to_spoken("![a waveform](/x.png)") == "image: a waveform."
      assert Speech.to_spoken("![](/x.png)") == "an image."
    end
  end

  describe "structure that carries no sound" do
    test "heading hashes, bullets, quotes and rules are dropped but their words kept" do
      spoken =
        Speech.to_spoken("""
        ## What changed

        - first thing
        - second thing

        > a quotation

        ---

        Done.
        """)

      assert spoken =~ "What changed"
      assert spoken =~ "first thing"
      assert spoken =~ "second thing"
      assert spoken =~ "a quotation"
      assert spoken =~ "Done."
      refute spoken =~ "##"
      refute spoken =~ "---"
      refute spoken =~ ">"
    end

    test "emphasis markers go, their words stay" do
      assert Speech.to_spoken("This is **very** important and *urgent*.") ==
               "This is very important and urgent."

      assert Speech.to_spoken("~~struck~~ out") == "struck out"
    end

    test "a table is announced rather than read cell by cell" do
      spoken =
        Speech.to_spoken("""
        Results:

        | Key | Value |
        |---|---|
        | a | 1 |
        | b | 2 |

        That is all.
        """)

      assert spoken =~ "Results:"
      assert spoken =~ "a table"
      assert spoken =~ "That is all."
      refute spoken =~ "|"
    end
  end

  describe "edges" do
    test "nil and empty are empty, so the caller can stay quiet" do
      assert Speech.to_spoken(nil) == ""
      assert Speech.to_spoken("") == ""
      assert Speech.to_spoken("   \n\n  ") == ""
    end

    test "a reply that is only code says just the announcement" do
      assert Speech.to_spoken("```sh\nls -la\n```") == "sh code block."
    end

    test "plain prose is returned unchanged" do
      assert Speech.to_spoken("Nothing special here at all.") == "Nothing special here at all."
    end

    test "runs of blank lines and spaces collapse" do
      assert Speech.to_spoken("One.\n\n\n\n\nTwo.   Three.") == "One.\n\nTwo. Three."
    end
  end
end
