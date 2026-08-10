defmodule BusterClaw.Notifications.Capture.LevelTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Capture.Level

  # osascript is a macOS system binary; the one test that actually invokes it
  # defines itself out on a machine that lacks it rather than failing.
  @osascript_available File.regular?("/usr/bin/osascript")

  # A runner that reports what it was asked to run and answers with `reply`.
  # Every rejection test uses one of these so "did not shell out" is an
  # assertion rather than an assumption.
  defp spy(reply) do
    parent = self()

    fn command, args ->
      send(parent, {:ran, command, args})
      reply
    end
  end

  describe "get/1 parsing" do
    test "a well-formed reply is the integer level" do
      assert {:ok, 100} = Level.get(runner: spy({"100\n", 0}))
      assert {:ok, 63} = Level.get(runner: spy({"63\n", 0}))
    end

    test "zero is a real level, not an error" do
      assert {:ok, 0} = Level.get(runner: spy({"0\n", 0}))
    end

    test "asks osascript for the input volume field, not the whole record" do
      assert {:ok, _level} = Level.get(runner: spy({"50", 0}))
      assert_receive {:ran, "/usr/bin/osascript", ["-e", script]}
      assert script == "input volume of (get volume settings)"
    end

    test "`missing value` is an error, distinct from a level of 0" do
      assert {:error, :no_input_device} = Level.get(runner: spy({"missing value\n", 0}))
    end

    test "unparseable output is an error" do
      for output <- ["", "\n", "banana", "12 34", "100.0", "true", "input volume:100"] do
        assert {:error, :unparseable_level} = Level.get(runner: spy({output, 0})),
               "#{inspect(output)} should not have parsed"
      end
    end

    test "a level outside 0..100 is unparseable, not clamped" do
      assert {:error, :unparseable_level} = Level.get(runner: spy({"101", 0}))
      assert {:error, :unparseable_level} = Level.get(runner: spy({"-1", 0}))
    end

    test "a non-zero exit is an error carrying the status" do
      assert {:error, {:osascript_failed, 1}} = Level.get(runner: spy({"syntax error", 1}))
    end

    test "a runner that cannot execute is an error, not a raise" do
      raiser = fn _command, _args -> raise ErlangError, original: :enoent end

      assert {:error, :no_osascript} = Level.get(runner: raiser)
    end
  end

  describe "set/2 validation" do
    test "accepts the endpoints and passes the level through as an integer" do
      assert :ok = Level.set(0, runner: spy({"", 0}))
      assert_receive {:ran, "/usr/bin/osascript", ["-e", "set volume input volume 0"]}

      assert :ok = Level.set(100, runner: spy({"", 0}))
      assert_receive {:ran, "/usr/bin/osascript", ["-e", "set volume input volume 100"]}
    end

    test "rejects out-of-range, non-integer and non-numeric input WITHOUT shelling out" do
      for bad <- [-1, 101, 1000, 50.5, 0.0, 100.0, "50", "", nil, :fifty, [50], %{}] do
        assert {:error, :invalid_volume} = Level.set(bad, runner: spy({"", 0})),
               "#{inspect(bad)} should have been rejected"

        refute_receive {:ran, _command, _args}
      end
    end

    test "rejects without a runner too — validation precedes any command lookup" do
      assert {:error, :invalid_volume} = Level.set(50.5)
      assert {:error, :invalid_volume} = Level.set(nil)
    end

    test "a non-zero exit is an error carrying the status" do
      assert {:error, {:osascript_failed, 2}} = Level.set(50, runner: spy({"nope", 2}))
    end

    test "a runner that cannot execute is an error, not a raise" do
      raiser = fn _command, _args -> raise ErlangError, original: :enoent end

      assert {:error, :no_osascript} = Level.set(50, runner: raiser)
    end
  end

  describe "against the real OS" do
    if @osascript_available do
      # Read-only on purpose: this test must never change the operator's input
      # volume, so there is no companion set/1 test here.
      test "get/0 reads the real default input, or says why it cannot" do
        case Level.get() do
          {:ok, level} -> assert level in 0..100
          {:error, reason} -> assert reason == :no_input_device
        end
      end
    end
  end
end
