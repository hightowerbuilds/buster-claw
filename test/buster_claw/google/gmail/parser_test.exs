defmodule BusterClaw.Google.Gmail.ParserTest do
  @moduledoc """
  Direct unit tests for the inbound parser. Gmail omits fields freely depending
  on the requested `format`, so most of what matters here is that a missing or
  odd shape degrades to `nil`/`[]` instead of raising inside a caller's `with`.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Google.Gmail.Parser

  describe "parse_message/1" do
    test "pulls headers, labels and the text body out of a full message" do
      message = Parser.parse_message(full_message())

      assert message.id == "msg-1"
      assert message.thread_id == "thread-1"
      assert message.subject == "Launch notes"
      assert message.from == "Ada <ada@example.com>"
      assert message.to == "Luke <luke@example.com>"
      assert message.label_ids == ["INBOX"]
      assert message.message_id_header == "<original-abc@mail.example.com>"
      assert message.body_text == "Hello from Gmail."
      assert message.body_html == nil
      assert message.raw == full_message()
    end

    test "finds a body nested several levels down a multipart tree" do
      nested = %{
        "payload" => %{
          "mimeType" => "multipart/mixed",
          "parts" => [
            %{
              "mimeType" => "multipart/alternative",
              "parts" => [
                %{"mimeType" => "text/plain", "body" => %{"data" => url64("deep text")}},
                %{"mimeType" => "text/html", "body" => %{"data" => url64("<p>deep html</p>")}}
              ]
            }
          ]
        }
      }

      message = Parser.parse_message(nested)

      assert message.body_text == "deep text"
      assert message.body_html == "<p>deep html</p>"
    end

    test "keeps the first part of each type when a message repeats them" do
      repeated = %{
        "payload" => %{
          "parts" => [
            %{"mimeType" => "text/plain", "body" => %{"data" => url64("first")}},
            %{"mimeType" => "text/plain", "body" => %{"data" => url64("second")}}
          ]
        }
      }

      assert Parser.parse_message(repeated).body_text == "first"
    end

    test "falls back to stripped HTML when there is no text/plain part" do
      html_only = %{
        "payload" => %{
          "parts" => [
            %{
              "mimeType" => "text/html",
              "body" => %{"data" => url64("<p>Hi &amp; bye<br>second line</p>")}
            }
          ]
        }
      }

      message = Parser.parse_message(html_only)

      assert message.body_text == "Hi & bye\nsecond line"
      assert message.body_html == "<p>Hi &amp; bye<br>second line</p>"
    end

    test "decodes the common HTML entities" do
      html = %{
        "payload" => %{
          "mimeType" => "text/html",
          "body" => %{"data" => url64("<b>&lt;a&gt;&nbsp;&quot;q&quot;&#39;s &amp; b</b>")}
        }
      }

      assert Parser.parse_message(html).body_text == ~s(<a> "q"'s & b)
    end

    test "undecodable body data becomes nil rather than raising" do
      broken = %{
        "payload" => %{"mimeType" => "text/plain", "body" => %{"data" => "!!!not base64!!!"}}
      }

      assert Parser.parse_message(broken).body_text == nil
    end

    test "an empty body yields all-nil fields" do
      message = Parser.parse_message(%{})

      assert message.id == nil
      assert message.subject == nil
      assert message.body_text == nil
      assert message.label_ids == []
    end

    test "parses internalDate from a string or an integer" do
      assert %{internal_date: %DateTime{} = from_string} =
               Parser.parse_message(%{"internalDate" => "1748361600000"})

      assert %{internal_date: %DateTime{} = from_int} =
               Parser.parse_message(%{"internalDate" => 1_748_361_600_000})

      assert from_string == from_int
      assert Parser.parse_message(%{"internalDate" => "not-a-number"}).internal_date == nil
      assert Parser.parse_message(%{"internalDate" => %{}}).internal_date == nil
    end
  end

  describe "message_summary/1" do
    test "returns the header fields without any body" do
      summary = Parser.message_summary(full_message())

      assert summary.id == "msg-1"
      assert summary.subject == "Launch notes"
      assert summary.from == "Ada <ada@example.com>"
      assert summary.label_ids == ["INBOX"]
      refute Map.has_key?(summary, :body_text)
      refute Map.has_key?(summary, :raw)
    end

    test "header lookup is case-insensitive on the header name" do
      body = %{"payload" => %{"headers" => [%{"name" => "SUBJECT", "value" => "Shouty"}]}}
      assert Parser.message_summary(body).subject == "Shouty"
    end
  end

  describe "label_summary/1, draft_summary/1 and sent_message_summary/1" do
    test "label_summary maps the visibility fields" do
      assert Parser.label_summary(%{
               "id" => "Label_1",
               "name" => "Clients",
               "type" => "user",
               "messageListVisibility" => "show",
               "labelListVisibility" => "labelShow"
             }) == %{
               id: "Label_1",
               name: "Clients",
               type: "user",
               message_list_visibility: "show",
               label_list_visibility: "labelShow"
             }
    end

    test "draft_summary reaches into the nested message" do
      summary =
        Parser.draft_summary(%{
          "id" => "draft-1",
          "message" => %{"id" => "msg-1", "threadId" => "thread-1"}
        })

      assert summary.id == "draft-1"
      assert summary.message_id == "msg-1"
      assert summary.thread_id == "thread-1"
    end

    test "draft_summary tolerates a response with no message" do
      assert %{id: "draft-1", message_id: nil, thread_id: nil} =
               Parser.draft_summary(%{"id" => "draft-1"})
    end

    test "sent_message_summary defaults labelIds to an empty list" do
      assert %{id: "msg-1", thread_id: "t", label_ids: []} =
               Parser.sent_message_summary(%{"id" => "msg-1", "threadId" => "t"})
    end
  end

  describe "history_summary/1" do
    test "collects changed ids from every event type and de-duplicates them" do
      summary =
        Parser.history_summary(%{
          "historyId" => "999",
          "history" => [
            %{"messages" => [%{"id" => "m1"}]},
            %{"messagesAdded" => [%{"message" => %{"id" => "m2"}}]},
            %{"labelsAdded" => [%{"message" => %{"id" => "m1"}}]},
            %{"labelsRemoved" => [%{"id" => "m3"}]}
          ]
        })

      assert summary.history_id == "999"
      assert summary.message_ids == ["m1", "m2", "m3"]
      assert summary.deleted_message_ids == []
    end

    test "a message deleted in the same window is excluded from the changed set" do
      summary =
        Parser.history_summary(%{
          "history" => [
            %{"messagesAdded" => [%{"message" => %{"id" => "m1"}}]},
            %{"messagesAdded" => [%{"message" => %{"id" => "m2"}}]},
            %{"messagesDeleted" => [%{"message" => %{"id" => "m2"}}]}
          ]
        })

      assert summary.message_ids == ["m1"]
      assert summary.deleted_message_ids == ["m2"]
    end

    test "drops nil and empty ids" do
      summary =
        Parser.history_summary(%{
          "history" => [%{"messages" => [%{"id" => nil}, %{"id" => ""}, %{"id" => "m1"}]}]
        })

      assert summary.message_ids == ["m1"]
    end

    test "an empty response yields empty lists, not nil" do
      summary = Parser.history_summary(%{})

      assert summary.history == []
      assert summary.message_ids == []
      assert summary.deleted_message_ids == []
      assert summary.next_page_token == nil
    end
  end

  defp url64(value), do: Base.url_encode64(value, padding: false)

  defp full_message do
    %{
      "id" => "msg-1",
      "threadId" => "thread-1",
      "snippet" => "Please review.",
      "labelIds" => ["INBOX"],
      "payload" => %{
        "mimeType" => "multipart/alternative",
        "headers" => [
          %{"name" => "Subject", "value" => "Launch notes"},
          %{"name" => "From", "value" => "Ada <ada@example.com>"},
          %{"name" => "To", "value" => "Luke <luke@example.com>"},
          %{"name" => "Message-ID", "value" => "<original-abc@mail.example.com>"},
          %{"name" => "Date", "value" => "Wed, 27 May 2026 09:00:00 -0700"}
        ],
        "parts" => [
          %{
            "mimeType" => "text/plain",
            "body" => %{"data" => Base.url_encode64("Hello from Gmail.", padding: false)}
          }
        ]
      }
    }
  end
end
