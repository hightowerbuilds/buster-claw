defmodule BusterClaw.Scripts.StaplerRetryTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/stapler_retry.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "bc_stapler_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    fake_command(dir, "xcrun", """
    printf '%s\\n' "$@" >> "$STAPLER_TEST_DIR/args"
    count=0
    if [ -f "$STAPLER_TEST_DIR/count" ]; then
      read -r count < "$STAPLER_TEST_DIR/count"
    fi
    count=$((count + 1))
    printf '%s\\n' "$count" > "$STAPLER_TEST_DIR/count"
    if [ "$count" -le "$STAPLER_TEST_FAILURES" ]; then
      exit 68
    fi
    """)

    fake_command(dir, "sleep", """
    printf '%s\\n' "$@" >> "$STAPLER_TEST_DIR/sleeps"
    """)

    {:ok, dir: dir}
  end

  test "successful validation runs once and forwards a path containing spaces", %{dir: dir} do
    path = Path.join(dir, "Buster Claw.app")
    assert {"", 0} = run(dir, ["validate", path], 0)
    assert File.read!(Path.join(dir, "count")) == "1\n"
    assert File.read!(Path.join(dir, "args")) == "stapler\nvalidate\n#{path}\n"
    refute File.exists?(Path.join(dir, "sleeps"))
  end

  test "a transient failure is retried and a successful staple passes", %{dir: dir} do
    assert {output, 0} = run(dir, ["staple", "Buster Claw.dmg"], 1)
    assert output =~ "retrying"
    assert File.read!(Path.join(dir, "count")) == "2\n"
    assert File.read!(Path.join(dir, "sleeps")) == "5\n"

    assert File.read!(Path.join(dir, "args")) ==
             String.duplicate("stapler\nstaple\nBuster Claw.dmg\n", 2)
  end

  test "persistent failure stops after three attempts and retains the failure code", %{dir: dir} do
    assert {output, 68} = run(dir, ["validate", "Buster Claw.dmg"], 10)
    assert output =~ "failed after 3 attempts"
    assert File.read!(Path.join(dir, "count")) == "3\n"
    assert File.read!(Path.join(dir, "sleeps")) == "5\n5\n"
  end

  test "invalid arguments fail without invoking Apple's tool", %{dir: dir} do
    for args <- [[], ["validate"], ["delete", "app"], ["staple", "app", "extra"]] do
      assert {output, 64} = run(dir, args, 0)
      assert output =~ "Usage:"
    end

    refute File.exists?(Path.join(dir, "count"))
  end

  defp fake_command(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/bash\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp run(dir, args, failures) do
    System.cmd("bash", [@script | args],
      env: [
        {"PATH", dir <> ":" <> System.fetch_env!("PATH")},
        {"STAPLER_TEST_DIR", dir},
        {"STAPLER_TEST_FAILURES", Integer.to_string(failures)}
      ],
      stderr_to_stdout: true
    )
  end
end
