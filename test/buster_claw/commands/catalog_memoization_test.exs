defmodule BusterClaw.Commands.CatalogMemoizationTest do
  # async: false — flips a global app-env key.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands

  setup do
    previous = Application.get_env(:buster_claw, :memoize_catalog)
    on_exit(fn -> Application.put_env(:buster_claw, :memoize_catalog, previous) end)
    :ok
  end

  test "the memoize setting is read at RUNTIME, not baked in at compile time" do
    # This is the regression that matters. As `Application.compile_env/3` the
    # same setting turned any stale _build into a hard boot failure —
    # "different value set for key :memoize_catalog during runtime compared to
    # compile time" — which took down the operator's dev server on 07-28. If
    # this test starts failing because the value is compiled in, the footgun is
    # back.
    Application.put_env(:buster_claw, :memoize_catalog, true)
    refute Commands.list_commands() == []

    Application.put_env(:buster_claw, :memoize_catalog, false)
    refute Commands.list_commands() == []
  end

  test "both modes return the same catalog" do
    Application.put_env(:buster_claw, :memoize_catalog, true)
    memoized = Commands.list_commands()

    Application.put_env(:buster_claw, :memoize_catalog, false)
    fresh = Commands.list_commands()

    assert memoized == fresh
  end

  test "with memoization off nothing is served from the cache" do
    Application.put_env(:buster_claw, :memoize_catalog, false)

    # Poison the cache with a value that would be obviously wrong if used.
    :persistent_term.put({Commands, :catalog}, [])
    on_exit(fn -> :persistent_term.erase({Commands, :catalog}) end)

    refute Commands.list_commands() == []
  end
end
