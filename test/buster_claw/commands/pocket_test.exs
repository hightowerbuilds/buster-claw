defmodule BusterClaw.Commands.PocketTest do
  # async: false — points the global :workspace_root at a temporary pockets dir.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Catalog
  alias BusterClaw.{Library, Pockets, Skills}

  # The command surface's reach, as a call graph. Every test below that talks
  # about what a command "can reach" walks this.
  @command_prefix "Elixir.BusterClaw.Commands"
  @core_prefix "Elixir.BusterClaw."

  # Function names that CREATE, CHANGE or REMOVE a mount. This is the whole of
  # D4: a mount is the record that lets a Pocket's bytes live outside the
  # workspace, it is written by the UI, and no command may reach a function that
  # writes one.
  #
  # Readers are deliberately NOT matched — `mounts/0`, `lookup_mount/1`,
  # `mounted?/1` are how a Pocket knows where its bytes are, and the agent is
  # allowed to read a mounted Pocket. It is only allowed never to make one.
  @mount_writer ~r/
    \A(un)?mount!?\z
    |\A(add|create|record|register|unregister|remove|delete|revoke|save|set|put|update|write)_mounts?!?\z
    |\Amounts?_(add|create|record|remove|delete|revoke|save|set|put|update|write)!?\z
  /x

  # Everything `BusterClaw.Commands.Pocket` calls inside the BusterClaw
  # namespace, exactly. This is the ACL-suite idiom and it is the strongest
  # guard here precisely because it is name-blind: whatever the mount registry
  # ends up being called, the Pocket command module cannot start calling it
  # without this list changing in a diff someone has to justify.
  @pocket_calls [
    {BusterClaw.Pockets, :contents, 1},
    {BusterClaw.Pockets, :dir, 0},
    {BusterClaw.Pockets, :list_with_errors, 0},
    {BusterClaw.Pockets, :load, 1},
    {BusterClaw.Pockets, :resolve, 2}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_pocket_cmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_pocket(name, opts) do
    dir = Pockets.pocket_dir(name)
    File.mkdir_p!(dir)

    case Keyword.get(opts, :manifest, :default) do
      nil ->
        :ok

      :default ->
        File.write!(Path.join(dir, "POCKET.md"), """
        ---
        name: #{name}
        kind: #{Keyword.get(opts, :kind, "icons")}
        description: Claw marks and hazard glyphs.
        roles: ["background"]
        ---

        The 32px versions are the ones that read at menu-bar size.
        """)

      manifest ->
        File.write!(Path.join(dir, "POCKET.md"), manifest)
    end

    for {file, body} <- Keyword.get(opts, :files, []) do
      File.write!(Path.join(dir, file), body)
    end

    dir
  end

  # --- pocket_list ------------------------------------------------------

  test "pocket_list summarises every valid Pocket and names the broken ones" do
    write_pocket("hazard-icons", files: [{"palette.css", ":root { --hazard: #FF4D1C; }"}])
    # A directory with no manifest is a BROKEN Pocket, not a missing one, and
    # the whole reason `invalid` is a separate list rather than a silence.
    write_pocket("half-made", manifest: nil)

    assert {:ok, result} = Commands.call("pocket_list", %{})

    assert result.counts == %{total: 2, valid: 1, invalid: 1}
    assert [%{name: "half-made", error: "no_manifest"}] = result.invalid

    assert [pocket] = result.pockets
    assert pocket.name == "hazard-icons"
    assert pocket.kind == "icons"
    assert pocket.description == "Claw marks and hazard glyphs."
    assert pocket.roles == ["background"]
    # Phase 1/2 are local-only; the field exists so a mounted Pocket reads
    # differently the day the registry lands, without this shape moving.
    assert pocket.binding == "local"
    refute pocket.writable
  end

  test "pocket_list is empty and untroubled when there are no Pockets at all" do
    assert {:ok, %{counts: %{total: 0}, pockets: [], invalid: []}} =
             Commands.call("pocket_list", %{})
  end

  # --- pocket_describe --------------------------------------------------

  test "pocket_describe carries the operator's own prose and the file listing" do
    write_pocket("hazard-icons",
      files: [{"palette.css", ":root {}"}, {"claw.png", <<137, 80, 78, 71, 0, 1, 2>>}]
    )

    assert {:ok, pocket} = Commands.call("pocket_describe", %{"name" => "hazard-icons"})

    # The body is the part a plain folder has never been able to carry.
    assert pocket.body =~ "menu-bar size"
    assert pocket.counts.files == 2

    assert [png, css] = pocket.files
    assert %{name: "claw.png", text: false} = png
    assert %{name: "palette.css", text: true, bytes: 8} = css
  end

  test "pocket_describe answers with the loader's reason when a Pocket does not load" do
    write_pocket("mislabelled", manifest: "---\nname: something-else\nkind: icons\n---\n")

    assert {:error, :name_mismatch} =
             Commands.call("pocket_describe", %{"name" => "mislabelled"})

    assert {:error, :no_manifest} = Commands.call("pocket_describe", %{"name" => "absent"})
    assert {:error, :invalid_name} = Commands.call("pocket_describe", %{"name" => "../etc"})
    assert {:error, :missing_name} = Commands.call("pocket_describe", %{})
  end

  # --- pocket_read ------------------------------------------------------

  test "pocket_read returns the text of one file" do
    write_pocket("hazard-icons", files: [{"palette.css", ":root { --hazard: #FF4D1C; }"}])

    assert {:ok, read} =
             Commands.call("pocket_read", %{"name" => "hazard-icons", "file" => "palette.css"})

    assert read.pocket == "hazard-icons"
    assert read.file == "palette.css"
    assert read.text
    refute read.truncated
    assert read.content == ":root { --hazard: #FF4D1C; }"
  end

  test "pocket_read succeeds on a binary file and returns no bytes" do
    # The bug this prevents: an icon rendered into a transcript. The agent
    # cannot see it, the operator pays for it in context, and the file's whole
    # purpose is to be displayed by something that can render it.
    write_pocket("hazard-icons", files: [{"claw.png", <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0>>}])

    assert {:ok, read} =
             Commands.call("pocket_read", %{"name" => "hazard-icons", "file" => "claw.png"})

    refute read.text
    assert read.content == nil
    assert read.bytes == 10
    assert read.note =~ "Not text"
  end

  test "pocket_read truncates a large text file rather than swallowing the conversation" do
    write_pocket("notes", kind: "free", files: [{"big.txt", String.duplicate("a", 70_000)}])

    assert {:ok, read} = Commands.call("pocket_read", %{"name" => "notes", "file" => "big.txt"})

    assert read.text
    assert read.truncated
    assert byte_size(read.content) == 64 * 1024
    assert read.bytes == 70_000
  end

  test "pocket_read takes a bare filename and nothing else", %{root: root} do
    write_pocket("hazard-icons", files: [{"palette.css", ":root {}"}])
    File.write!(Path.join(root, "secret.txt"), "operator secrets")
    File.mkdir_p!(Path.join(Pockets.pocket_dir("hazard-icons"), "sub"))
    File.write!(Path.join([Pockets.pocket_dir("hazard-icons"), "sub", "nested.txt"]), "nested")

    for file <- ["../secret.txt", "sub/nested.txt", "/etc/hosts", ".hidden", ""] do
      assert {:error, :not_found} =
               Commands.call("pocket_read", %{"name" => "hazard-icons", "file" => file}),
             "#{inspect(file)} should not be readable"
    end

    assert {:error, :not_found} =
             Commands.call("pocket_read", %{"name" => "hazard-icons", "file" => "gone.css"})

    assert {:error, :missing_name_or_file} = Commands.call("pocket_read", %{"name" => "x"})
  end

  test "a symlink planted inside a Pocket is refused, not followed", %{root: root} do
    dir = write_pocket("hazard-icons", files: [{"palette.css", ":root {}"}])
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "not yours")

    case File.ln_s(outside, Path.join(dir, "escape.txt")) do
      :ok ->
        assert {:error, :not_found} =
                 Commands.call("pocket_read", %{
                   "name" => "hazard-icons",
                   "file" => "escape.txt"
                 })

        # And it is not even listed: `contents/1` walks with lstat for the same
        # reason `resolve/2` does.
        assert {:ok, %{files: files}} =
                 Commands.call("pocket_describe", %{"name" => "hazard-icons"})

        refute Enum.any?(files, &(&1.name == "escape.txt"))

      {:error, _} ->
        # A filesystem that cannot make one has nothing to prove here.
        :ok
    end
  end

  # --- the tier actually holds ------------------------------------------

  test "the pocket reads run for an untrusted caller and nothing else does" do
    write_pocket("hazard-icons", files: [{"palette.css", ":root {}"}])

    assert {:ok, _} = Commands.call("pocket_list", %{}, caller: :mcp)
    assert {:ok, _} = Commands.call("pocket_describe", %{"name" => "hazard-icons"}, caller: :mcp)

    assert {:ok, _} =
             Commands.call(
               "pocket_read",
               %{"name" => "hazard-icons", "file" => "palette.css"},
               caller: :mcp
             )
  end

  # --- D4: THE LOCKSTEP -------------------------------------------------
  #
  # "Mounting is an operator act in the UI. There is no mount command, at any
  # tier, ever." — POCKETS_ROADMAP D4.
  #
  # Enforced structurally rather than by a policy check, so these four tests are
  # the enforcement. They are layered on purpose: the first two stop the verb
  # being *declared*, the third stops it being *reached* through anything the
  # command surface calls, and the fourth is name-blind, so it holds even if a
  # future mount registry is called something none of these regexes anticipate.

  describe "D4 — no command can create, change or remove a mount" do
    test "no catalogued command's name or arguments mention mounting" do
      offenders =
        Catalog.entries()
        |> Enum.filter(fn entry ->
          Regex.match?(~r/mount/i, entry.name) or
            Enum.any?(Map.keys(entry.args), &Regex.match?(~r/mount/i, &1))
        end)
        |> Enum.map(& &1.name)

      assert offenders == [],
             """
             A command names a mount: #{inspect(offenders)}

             POCKETS_ROADMAP D4 is absolute — a mount is the record that lets a
             Pocket's bytes live outside the workspace, and it is written by the
             operator in the UI and by nothing else. Do not add a tier to this
             verb; delete the verb.
             """
    end

    test "the pocket surface is exactly three read verbs at :safe" do
      entries =
        Catalog.entries()
        |> Enum.filter(&String.starts_with?(&1.name, "pocket_"))
        |> Enum.sort_by(& &1.name)

      assert Enum.map(entries, & &1.name) == ["pocket_describe", "pocket_list", "pocket_read"],
             """
             The Pocket surface changed. Phase 4 is deliberately three read verbs
             "and no more until something wants more" — a fourth is a decision,
             not a detail. Write verbs are out of scope for this phase entirely.
             """

      for entry <- entries do
        assert entry.type == :read, "#{entry.name}: must be a read"
        assert entry.tier == :safe, "#{entry.name}: must be :safe"
        refute Map.get(entry, :gated, false), "#{entry.name}: a read has nothing to gate"
      end
    end

    test "the facade exports no mount-shaped function at all" do
      # `call/2` dispatches with `apply/3` against this module, so a function
      # here is reachable whether or not it is catalogued.
      offenders =
        BusterClaw.Commands.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
        |> Enum.filter(&Regex.match?(~r/mount/i, &1))
        |> Enum.uniq()

      assert offenders == [], "BusterClaw.Commands exports: #{inspect(offenders)}"
    end

    test "nothing reachable from the command surface writes a mount" do
      {modules, calls} = command_call_graph()

      # A guard over an empty set is vacuously green — the failure mode the doc
      # comb found clustering at exactly this seam. Prove the walk walked.
      assert MapSet.size(modules) > 50,
             "the call-graph walk found only #{MapSet.size(modules)} modules; it is not walking"

      offenders =
        calls
        |> Enum.filter(fn {_m, f, _a} -> Regex.match?(@mount_writer, Atom.to_string(f)) end)
        |> Enum.uniq()

      assert offenders == [],
             """
             A command module transitively calls a mount writer: #{inspect(offenders)}

             The command surface is on the USING side of the mount split, never
             the managing side — the same shape The Clinch used to let a remote
             caller use a credential but never manage one. Reading a mounted
             Pocket is fine; recording, changing or removing the mount is not.
             """
    end

    test "the Pocket command module's reach is exactly the audited fence" do
      assert internal_calls(BusterClaw.Commands.Pocket) == @pocket_calls,
             """
             `BusterClaw.Commands.Pocket` calls something new inside BusterClaw.

             This list is name-blind on purpose: it is the guard that still works
             when the mount registry is called something nobody predicted. If the
             new call is legitimate, add it here and say in the commit why the
             Pocket command surface needed to reach further.

             Note especially that every byte returned must come through
             `Pockets.resolve/2` — the one canonicalizing, lstat-ing fence. Two
             places that build paths is how one of them ends up wrong.
             """
    end
  end

  # --- catalog / handler lockstep ---------------------------------------

  test "every argument the handler reads is declared in the catalog, and vice versa" do
    source = File.read!(Path.join(File.cwd!(), "lib/buster_claw/commands/pocket.ex"))

    read =
      [
        ~r/"([a-z][a-z0-9_]*)"\s*=>/,
        ~r/args\[\s*"([a-z][a-z0-9_]*)"\s*\]/,
        ~r/Map\.(?:get|fetch|fetch!|has_key\?)\(\s*args\s*,\s*"([a-z][a-z0-9_]*)"/
      ]
      |> Enum.flat_map(&(Regex.scan(&1, source) |> Enum.map(fn [_, key] -> key end)))
      |> MapSet.new()

    declared =
      Catalog.entries()
      |> Enum.filter(&String.starts_with?(&1.name, "pocket_"))
      |> Enum.flat_map(&Map.keys(&1.args))
      |> MapSet.new()

    assert read == declared,
           """
           The catalog and the handler disagree about arguments.
           handler reads: #{inspect(MapSet.to_list(read))}
           catalog declares: #{inspect(MapSet.to_list(declared))}

           An undeclared argument a handler honours is the same class of error as
           an invented verb: the model is told one contract and the code keeps
           another.
           """
  end

  # --- the reference skill ----------------------------------------------

  test "ensure seeds the pockets skill, and it loads as a read-only reference" do
    assert :ok = Skills.ensure()

    assert {:ok, skill} = Skills.load("pockets")
    assert skill.handler_kind == :reference
    assert skill.enabled
    assert skill.tier == :safe
    assert skill.steps == []
    assert skill.body =~ "pocket_describe"

    # Discoverable (it is how the agent finds the playbook) but never runnable.
    assert Enum.any?(Skills.list(), &(&1.name == "pockets"))
    assert :error = Skills.fetch("pockets")
    refute Enum.any?(Commands.list_skills(), &(&1.name == "pockets"))
  end

  test "every pocket_* verb the skill names exists in the live catalog" do
    # A reference skill that names a verb the catalog does not have teaches a
    # command that cannot be run. It is also why the skill says "there is no
    # command for mounting" in words rather than by naming the verb it would
    # have been — naming it here would be teaching it.
    assert :ok = Skills.ensure()
    assert {:ok, skill} = Skills.load("pockets")

    catalog = MapSet.new(Commands.list_commands(), & &1.name)

    named =
      ~r/\bpocket_[a-z_]+/
      |> Regex.scan(skill.body)
      |> List.flatten()
      |> MapSet.new()

    refute Enum.empty?(named), "the skill should name the verbs it teaches"

    assert MapSet.subset?(named, catalog),
           "unknown verb(s): #{inspect(MapSet.to_list(MapSet.difference(named, catalog)))}"
  end

  # --- call-graph helpers -----------------------------------------------

  # Remote calls are read from each module's BEAM `imports` chunk, which is the
  # compiler's own record of what the module calls. It sees static remote calls
  # and not `apply/3` with a computed name — stated as a limit rather than
  # hidden, and it is why the D4 guard is layered instead of relying on this
  # alone.
  defp command_call_graph do
    modules = app_modules()
    core = modules |> Enum.filter(&core?/1) |> MapSet.new()
    seeds = Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), @command_prefix))

    walk(seeds, core, MapSet.new(), [])
  end

  defp walk([], _core, seen, calls), do: {seen, Enum.uniq(calls)}

  defp walk([module | rest], core, seen, calls) do
    if MapSet.member?(seen, module) do
      walk(rest, core, seen, calls)
    else
      imports = imports(module)
      next = for {m, _f, _a} <- imports, MapSet.member?(core, m), do: m
      walk(rest ++ next, core, MapSet.put(seen, module), calls ++ imports)
    end
  end

  defp internal_calls(module) do
    module
    |> imports()
    |> Enum.filter(fn {m, _f, _a} -> core?(m) end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  # `BusterClawWeb.*` is deliberately NOT core: the UI is the surface that
  # RECORDS mounts, so pulling it into the closure would flag the one caller
  # that is supposed to exist.
  defp core?(module), do: String.starts_with?(Atom.to_string(module), @core_prefix)

  defp app_modules do
    {:ok, modules} = :application.get_key(:buster_claw, :modules)
    modules
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {_module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _ -> []
    end
  end
end
