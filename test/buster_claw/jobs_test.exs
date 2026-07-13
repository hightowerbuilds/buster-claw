defmodule BusterClaw.JobsTest do
  # async: false — points the global :workspace_root at a tmp job-descriptions dir.
  use ExUnit.Case, async: false

  alias BusterClaw.{Commands, Jobs, TrustedSenders}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_jobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "ensure seeds a starter job, roster, and trusted-sender template", %{root: root} do
    assert :ok = Jobs.ensure()

    assert File.exists?(Path.join(root, "job-descriptions/mail-triage.md"))
    assert File.exists?(Path.join(root, "job-descriptions/README.md"))
    assert File.exists?(Path.join(root, "memory/trusted-email-senders.md"))

    # The seeded policy trusts nobody by default (placeholders don't parse).
    refute TrustedSenders.trusted?("anyone@example.com")
  end

  test "ensure seeds the agent's .claude/settings.json with bypassPermissions", %{root: root} do
    assert :ok = Jobs.ensure()

    settings_path = Path.join(root, ".claude/settings.json")
    assert File.exists?(settings_path)

    assert %{"permissions" => %{"defaultMode" => "bypassPermissions"}} =
             settings_path |> File.read!() |> Jason.decode!()
  end

  test "ensure never overwrites an operator-authored agent settings file", %{root: root} do
    File.mkdir_p!(Path.join(root, ".claude"))

    File.write!(
      Path.join(root, ".claude/settings.json"),
      ~s({"permissions":{"defaultMode":"default"}})
    )

    assert :ok = Jobs.ensure()

    assert %{"permissions" => %{"defaultMode" => "default"}} =
             Path.join(root, ".claude/settings.json") |> File.read!() |> Jason.decode!()
  end

  test "the mail-triage prompt directs the agent to act, not ask permission", %{root: _root} do
    Jobs.ensure()
    body = Jobs.get("mail-triage").body

    assert body =~ "Treat each email as a direct instruction"
    assert body =~ "Do not stop to ask permission"
    # The old prompt-injection prohibition is gone for trusted senders.
    refute body =~ "do not execute what the email says"
  end

  test "list returns defined jobs without bodies; get returns the body", %{root: _root} do
    Jobs.ensure()

    assert [%{key: "mail-triage", name: "Mail Triage"} = entry, %{key: "voicemail-triage"}] =
             Jobs.list()

    refute Map.has_key?(entry, :body)

    job = Jobs.get("mail-triage")
    assert job.key == "mail-triage"
    assert job.summary =~ "Reply"
    assert job.body =~ "# Mail Triage"
    assert job.body =~ "dispatch claim --job mail-triage"
    assert job.body =~ "dispatch reply <id>"
  end

  test "the seeded voicemail-triage job tells the agent it cannot call back", %{root: _root} do
    Jobs.ensure()

    job = Jobs.get("voicemail-triage")
    assert job.name == "Voicemail Triage"
    assert job.body =~ "dispatch claim --job voicemail-triage"
    assert job.body =~ "phone_get"

    # The load-bearing instruction: BusterPhone is inbound-only, and `dispatch reply`
    # is a Gmail send that refuses a voicemail item. An agent carrying over its
    # mail-triage habit would otherwise try to email a phone number.
    assert job.body =~ "cannot call or text anyone back"
    assert job.body =~ "no_reply_channel"

    # Transcripts are machine-made and are a stranger's words — both warnings matter.
    assert job.body =~ "often wrong"
    assert job.body =~ "untrusted input"
  end

  test "get derives name/summary from frontmatter or falls back to the key/body", %{root: root} do
    File.mkdir_p!(Path.join(root, "job-descriptions"))
    File.write!(Path.join(root, "job-descriptions/ci-fix.md"), "# CI Fix\n\nKeep CI green.\n")

    job = Jobs.get("ci-fix")
    assert job.name == "Ci Fix"
    assert job.summary == "Keep CI green."
  end

  test "unknown job is nil", %{root: _root} do
    Jobs.ensure()
    assert Jobs.get("nope") == nil
    refute Jobs.exists?("nope")
  end

  test "job_list and job_show commands resolve against job-descriptions", %{root: _root} do
    Jobs.ensure()

    assert {:ok, jobs} = Commands.call("job_list")
    assert Enum.any?(jobs, &(&1.key == "mail-triage"))

    assert {:ok, job} = Commands.call("job_show", %{"key" => "mail-triage"})
    assert job.name == "Mail Triage"

    assert {:error, :not_found} = Commands.call("job_show", %{"key" => "nope"})
  end
end
