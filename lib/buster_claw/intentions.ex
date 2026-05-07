defmodule BusterClaw.Intentions do
  @moduledoc "Prompt and report text builders for deterministic analysis runs."

  alias BusterClaw.Library.Document

  def analysis_messages(%Document{} = document, body) when is_binary(body) do
    [
      %{
        role: "system",
        content:
          "You are Buster Claw's analysis worker. Produce a concise markdown report with summary, signals, risks, and next actions."
      },
      %{
        role: "user",
        content: """
        Analyze this fetched document.

        Filename: #{document.filename}
        Name: #{document.name || document.filename}
        Source URL: #{document.source_url || "unknown"}
        Date: #{format_date(document.date)}

        Document:
        #{String.trim(body)}
        """
      }
    ]
  end

  def report_markdown(%Document{} = document, content, metadata) do
    title = document.name || document.filename

    """
    # Analysis Report: #{title}

    #{metadata_block(metadata)}

    #{String.trim(content)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp metadata_block(metadata) do
    [
      {"Document", metadata[:source_file]},
      {"Source", metadata[:source_url]},
      {"Provider", metadata[:provider_name]},
      {"Model", metadata[:model]},
      {"Generated", metadata[:generated_at]}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
    |> Enum.map_join("\n", fn {label, value} -> "- #{label}: #{value}" end)
  end

  defp format_date(nil), do: "unknown"
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
end
