defmodule BusterClaw.Notes.LinksTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notes.Links

  # Resolves anything under Projects/ plus one root note; everything else is a
  # missing target, which is the case the "create this note" affordance needs.
  defp resolve("Remote access"), do: "Remote access.md"
  defp resolve("Projects/Launch"), do: "Projects/Launch.md"
  defp resolve(_target), do: nil

  describe "parse/1" do
    test "reads bare targets, folder paths, and aliases" do
      body = "See [[Remote access]], [[Projects/Launch|the plan]], and [[Ghost]]."

      assert Links.parse(body) == [
               %{target: "Remote access", label: nil},
               %{target: "Projects/Launch", label: "the plan"},
               %{target: "Ghost", label: nil}
             ]
    end

    test "a label may contain pipes without truncating the user's text" do
      assert [%{target: "Note", label: "a | b"}] = Links.parse("[[Note|a | b]]")
    end

    test "fenced blocks and inline code are not link syntax" do
      body = """
      Real: [[Remote access]]

      ```
      [[Fenced]]
      ```

      Inline `[[Spanned]]` stays code.

      ~~~markdown
      [[Tilde fenced]]
      ~~~
      """

      assert Links.parse(body) == [%{target: "Remote access", label: nil}]
    end

    test "a longer fence contains shorter runs without ending early" do
      body = """
      ````
      ```
      [[Inner]]
      ```
      ````

      [[Outer]]
      """

      assert Links.parse(body) == [%{target: "Outer", label: nil}]
    end

    test "an unterminated fence keeps the rest of the document as code" do
      # The user is mid-typing. Flickering their sample into links until they
      # close the fence would be the worst possible moment for it.
      assert Links.parse("```\n[[Still typing]]\n") == []
    end
  end

  describe "replace/2" do
    test "known targets become note fragments and missing ones become create links" do
      out = Links.replace("[[Remote access]] then [[Ghost]]", &resolve/1)

      assert out == "[Remote access](#note/Remote+access.md) then [Ghost](#note-new/Ghost)"
    end

    test "an alias becomes the link text, and the path is encoded" do
      assert Links.replace("[[Projects/Launch|the plan]]", &resolve/1) ==
               "[the plan](#note/Projects%2FLaunch.md)"
    end

    test "documents without links come back byte-identical" do
      body = "no links here\n\n```\nfence\n```\n\ntrailing\n"

      assert Links.replace(body, &resolve/1) == body
    end

    test "code regions survive the rewrite untouched" do
      body = "```\n[[Fenced]]\n```\n\n`[[Spanned]]` and [[Ghost]]\n"

      assert Links.replace(body, &resolve/1) ==
               "```\n[[Fenced]]\n```\n\n`[[Spanned]]` and [Ghost](#note-new/Ghost)\n"
    end
  end
end
