defmodule BusterClawWeb.Explained.Shaders do
  @moduledoc """
  The Shaders & Backgrounds tutorial — the one surface in Explained where the
  agent cannot press the button.

  Appearance has **no commands**. There is no `appearance_*` or `shader_*` entry
  in the catalog, and that absence is the security property this tutorial
  teaches: an author (you, or an agent with file access to the workspace) can
  *propose* a pattern by writing `shaders/<name>.wgsl`, but only a human click in
  Settings → Appearance ever puts it on screen. Writing the file changes nothing
  you can see.

  Two things here disagreed with the code before this was written, and both are
  now taken from the implementation rather than from the older prose:

  - The catalog is **click**, not drag. Every row carries one button per surface
    (`AppearanceLive.option_chip/1` → `assign_button`). `Appearance`'s own
    moduledoc still said "drags an option onto the target" — corrected in the
    same commit as this file.
  - There is **no palette-coloured fallback** when WebGPU is missing. The shader
    layer simply does not paint (`.ic-home-bg` has no background of its own), so
    the surface reads as solid — which is what the Appearance page itself says.

  The `shaders/` naming rule is load-bearing and easy to get wrong: `face` as a
  dash-separated word makes the file a contact **shaderface** for `/phone`, and
  such a file is refused as a background — in the picker *and* on read, so an
  older stored selection degrades rather than rendering a face behind the
  homepage.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  alias BusterClaw.Appearance

  def shaders_panel(assigns) do
    assigns =
      assign(assigns,
        builtins: Appearance.builtin_shaders(),
        max_images: Appearance.max_images(),
        extensions: Enum.map_join(Appearance.accepted_extensions(), " ", &String.trim(&1, "."))
      )

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Ambiance</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Shaders & Backgrounds — the one thing the agent can't switch on
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          That drift behind this page is not a video and not a GIF. It is a real
          WGSL shader, compiled in the webview and rendered on the GPU every frame.
          Two surfaces in the app can carry one — the
          <span class="font-semibold text-base-content">homepage</span>
          and the <span class="font-semibold text-base-content">terminal</span>
          — and they draw from a single shared catalog you can add to.
        </p>
        <p class="border-l-2 border-primary pl-3">
          <span class="font-semibold text-base-content">There are no commands on this
            tab, on purpose.</span>
          Every other tutorial in this rail teaches you what to ask an agent for.
          This one cannot: nothing in the command surface selects a background. An
          agent with file access can *write* a shader into your workspace and
          suggest it — but putting it on your screen is a click only you can make.
          That is the entire safety model for arbitrary GPU code, and it is why the
          gap is deliberate rather than unfinished.
        </p>
      </div>

      <section class="flex flex-col gap-3" id="explained-shader-catalog">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          One catalog, two targets
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          <.link navigate="/appearance" class="font-semibold text-primary hover:opacity-80">
            Settings → Appearance
          </.link>
          shows the catalog once, on the left, and the two surfaces on the right,
          each previewing what it is actually running. Every catalog row has one
          button per surface, so pointing something at a surface is a single click —
          and the same option can back both at the same time, which is exactly why
          it is one catalog and not two pickers.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">Off</span>
            — no background. The terminal ships this way; a bare terminal reads as
            plain, where a bare homepage reads as broken.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">Built-in shaders</span>
            — {Enum.join(@builtins, ", ")}. Bundled with the app, so they need no
            files and no fetch. The homepage ships on <code>smoke</code>. Weather is
            the odd one: it is fed your location's real conditions and time of day,
            so it rains on screen when it rains outside.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">Workspace shaders</span>
            — anything valid in your workspace's <code>shaders/</code>
            folder, listed by name. This is the part you write.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">Images</span>
            — up to {@max_images} slots ({@extensions}), uploaded with <span class="italic">Add to catalog</span>. Adding one never changes what
            a surface is showing; it joins the pool and waits to be chosen.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/70">
          Shaders are named rather than pictured. A live thumbnail per row would mean
          a GPU device per row, and the only honest preview of a shader is the shader
          — which is what the two surface panels are for.
        </p>
      </section>

      <.example
        n={1}
        title="Change what's behind this page"
        want="Before writing any WGSL, drive the thing that already works."
        needs="The desktop app — shaders need WebGPU. Nothing else; the built-ins ship with the app."
        touches="One setting per surface. Changes nothing on disk and nothing outside the app's own appearance."
        confirm="None, and none is needed: it is your click, it is instant, and it is reversible by clicking something else."
        result="The homepage redraws immediately — the shader layer remounts on any change. Where WebGPU is unavailable the layer simply does not paint and the surface stays solid; the app over it is unaffected."
      >
        <ol class="ic-unfold">
          <li>
            Open
            <.link navigate="/appearance" class="font-semibold text-primary hover:opacity-80">
              Appearance
            </.link>
            and find a built-in in the Shaders list — try <code>waves</code>
            or <code>mandel</code>.
          </li>
          <li>
            Click that row's <span class="font-semibold text-base-content">Home</span>
            button. The homepage panel on the right starts running it, and so does
            the page behind you.
          </li>
          <li>
            With a shader on a surface, that surface offers
            <span class="italic">Use custom colors</span>
            — three pickers labelled <span class="font-semibold text-base-content">Base</span>,
            <span class="font-semibold text-base-content">Accent</span>
            and <span class="font-semibold text-base-content">Highlight</span>. Those are
            the three colors every shader is handed; leave the box unchecked and the
            design's own palette applies.
          </li>
          <li>
            Prefer stillness? The background respects your system's reduced-motion
            setting on its own — it drops the grain and slows right down without you
            configuring anything.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Give the terminal its own"
        want="Two surfaces, independently set, from the one list."
        needs="Nothing beyond the desktop app. An image target additionally needs an image in the pool."
        touches="The terminal's own background setting, stored separately from the homepage's."
        confirm="None. Open terminals re-render live when it changes — no restart, no reopen."
        result="The terminal panel previews it immediately. Clear a pool slot that a surface is using and that surface falls back to its own default rather than jumping to some other image you didn't pick."
      >
        <ol class="ic-unfold">
          <li>
            Same catalog rows, the <span class="font-semibold text-base-content">Terminal</span>
            button instead. A row already in use is marked, so you can see at a
            glance what is driving what.
          </li>
          <li>
            Palettes are per surface too: the same shader can run warm behind the
            homepage and cold behind the terminal.
          </li>
          <li>
            Images work the same way once uploaded — but note that a background image
            is a picture, so the palette controls do not apply to it.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-shader-contract">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Writing one: the file contract
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          A custom pattern is <span class="font-semibold text-base-content">one file</span>:
          <code>shaders/&lt;name&gt;.wgsl</code>
          in your workspace. It holds <span class="font-semibold text-base-content">only</span>
          the fragment entry point — <code>fn fs_main(...) -&gt; @location(0) vec4&lt;f32&gt;</code>
          — because a shared prelude is prepended for you in the browser: the
          uniforms, the noise helpers (<code>hash</code>, <code>fbm</code>, <code>grad3</code>), the post-processing pass, and the <code>colA</code>/<code>colB</code>/<code>colC</code> palette that the three color pickers feed. The result is compiled live via
          WebGPU, so a new pattern needs <span class="font-semibold text-base-content">no recompile and no rebuild
            of the app</span>.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">The name decides
              where it can appear.</span>
            A name with <code>face</code>
            as a dash-separated word — <code>viking-face</code>, <code>face-luke</code>
            — is a contact <span class="font-semibold text-base-content">shaderface</span>
            for the Phone tab's face picker, and is never offered or honored as a
            background. Anything else is a background, and a background
            <span class="italic">may</span>
            also be picked as a face. The flow runs one way.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">
              Names are <code>[a-z0-9-]</code>.
            </span>
            Lowercase, starting with a letter or digit. A name that does not match is
            not read at all — which is also what stops a name from wandering out of
            the folder.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">
              It must define <code>fs_main</code>, and stay under 64 KB.
            </span>
            A file that fails either check is simply not listed. There is no broken
            entry to clean up.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">A built-in name
              wins.</span> Call yours <code>smoke</code> and the bundled Smoke shadows it. Pick
            another name.
          </li>
        </ul>
        <p class="text-sm leading-relaxed text-base-content/70">
          The full prelude contract — every uniform, what each helper returns, worked
          examples — is the <code>shader-designer</code>
          skill in your workspace's <code>skills/</code>
          folder. Point an agent at that file rather than describing the interface to
          it from memory.
        </p>
      </section>

      <.example
        n={3}
        title="Have the agent write you one"
        want="Describe a look; get a file. Then decide whether it goes on your screen."
        needs="An agent CLI signed in, and the shader-designer skill in your workspace (it ships seeded)."
        touches="Writes one file, `shaders/<name>.wgsl`, in your workspace. It touches no setting and no surface."
        confirm="The hard stop is structural: there is no command that selects a background, so the agent cannot apply what it wrote. Selection is your click, always."
        result="A new row in the Appearance catalog under Shaders, once the page reads the folder again. Invalid WGSL never appears there; a file that compiles but throws leaves the surface unpainted rather than crashing the page."
      >
        <.prompt text="Read the shader-designer skill, then write me a background shader called deep-tide — slow diagonal swells, mostly dark, with the accent color only in the crests. Put it in my shaders folder and tell me what to click." />
        <ol class="ic-unfold">
          <li>
            The agent reads the skill for the prelude contract, then writes
            <code>shaders/deep-tide.wgsl</code>
            with your workspace file tools — not through a Buster Claw command, because
            there isn't one for this. It is an ordinary file in an ordinary folder.
          </li>
          <li>
            Nothing changes on screen.
            <span class="font-semibold text-base-content">This is the part people
              expect to be broken and it isn't.</span>
            The file exists; the shader is not running; your homepage looks exactly as
            it did.
          </li>
          <li>
            Open Appearance. <code>Deep Tide</code>
            is now a row in the Shaders list. Click
            <span class="font-semibold text-base-content">Home</span>
            and it starts drifting — fetched by name, prelude prepended, compiled in
            place.
          </li>
          <li>
            Iterate in the same breath: "make the crests sharper" rewrites the file,
            and the shader layer picks up the new source on remount. Delete the file
            and the surface falls back to its default instead of going blank.
          </li>
        </ol>
      </.example>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/70">
        <p>
          <span class="font-semibold text-base-content">When it doesn't draw.</span>
          Shaders want WebGPU, which means the desktop app; in a plain browser the
          layer stays unpainted and the surface reads as solid. A shader that fails
          to compile, or a custom file that cannot be fetched, does the same thing —
          the app is never held hostage by its own wallpaper. And anything stale
          degrades rather than breaking: a selection pointing at a deleted file or an
          emptied image slot resolves to that surface's default on the next read.
        </p>
        <p>
          <span class="font-semibold text-base-content">Why this one is manual.</span>
          A shader is code that runs on your GPU. It is sandboxed — WGSL cannot reach
          memory or the filesystem — but it can still own every pixel behind your
          work, and a surface you cannot read is a surface you cannot trust. So the
          catalog is generous about what may be *offered* and absolute about who
          *chooses*. Files can arrive from anywhere. Selection stays with you.
        </p>
      </div>

      <.link
        navigate="/appearance"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open Appearance
      </.link>
    </div>
    """
  end
end
