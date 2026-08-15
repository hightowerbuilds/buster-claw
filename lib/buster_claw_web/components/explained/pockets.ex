defmodule BusterClawWeb.Explained.Pockets do
  @moduledoc """
  The Pockets tutorial — a folder the app knows the purpose of, and the one rule
  that keeps a description from becoming a permission.

  ## Why this tab exists at all

  The standing rule from the archived Explore work is that *eight thin tutorials
  are worth less than five good ones*, so a ninth tile needs an argument. This
  one has the argument the five parked candidates lacked: the word is **already
  load-bearing in three other surfaces**. Appearance's background pool is
  `pockets/backgrounds/` (`BusterClaw.Appearance`), the dock icons and the
  homepage banner are six Pockets (`BusterClaw.Pockets.Brand`), and every contact
  shaderface lives in one (`BusterClaw.Pockets.Faces`). A reader meets the word
  three times with no page to send them to.

  ## The spine of this page

  `BusterClaw.Pocket`'s own moduledoc states it in one line — **the manifest
  holds description, it never holds permission** — and everything here is built
  on that rather than on a restatement of it. `POCKET.md` sits inside the
  workspace and the agent can write files in the workspace, so every field the
  manifest carries is a *label*, and everything that decides reach lives in
  app-owned state the command surface cannot address.

  The sharpest consequence, and the sentence this page is written to deliver:
  **roles describe a Pocket, they never decide one.** `Appearance`'s `@pocket`
  is the fixed string `"backgrounds"` rather than a `Pockets.for_role/1` lookup,
  *precisely so* a malformed or duplicate manifest can never silently relocate
  where a user's uploads are written — even though that Pocket's own manifest
  does declare `roles: ["background"]`. `Pockets.Brand` (D10) and
  `Pockets.Faces` made the same call, and Faces states the stake plainly: a
  role-bound face Pocket would let an agent redirect every contact's face at
  once by writing a manifest.

  ## What was left out, deliberately

  The `:pages` kind, `asset_url/2`'s cache stamp, the `/pockets/:name/:file`
  route, and the thumbnail rules in `PocketsPanel` are all true and none of them
  changes what a reader does next. Cardinality (D11) appears only where it is
  visible — the brand slot that shows a text label — rather than as a design
  note.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  def pockets_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">Your own material</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Pockets — a folder the app knows the purpose of
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          A Pocket is one directory under <code>pockets/</code>
          in your workspace, holding a <code>POCKET.md</code>
          manifest and the media that manifest describes. That is the whole idea. The
          folder was always yours; the manifest is what lets the app — and the agent —
          say something true about it without opening every file.
        </p>
        <p>
          The manifest is frontmatter and prose. Four fields: <code>name</code>, <code>kind</code>,
          <code>description</code>
          and <code>roles</code>
          — then anything you write below the dashes, which the app shows under the file
          list. That last part is what a plain folder has never been able to carry, and
          it is routinely where you said which file is the master and which are derived.
          <span class="font-semibold text-base-content">New</span>
          on the Pockets tab writes it for you; it never overwrites one you have edited.
        </p>
        <p>
          <code>kind</code>
          is one of <code>icons</code>, <code>badges</code>, <code>banners</code>, <code>fonts</code>, <code>media</code>,
          <code>pages</code>
          or <code>free</code>, and <code>free</code>
          is a real answer rather than a fallback. The directory name is the truth: a
          manifest naming something else is <span class="font-semibold text-base-content">refused rather than renamed</span>, so a Pocket can never be addressed by two names.
        </p>
        <p class="border-l-2 border-primary pl-3">
          <span class="font-semibold text-base-content">
            The manifest holds description. It never holds permission.
          </span>
          <code>POCKET.md</code>
          lives in the workspace, and the agent can write files in the workspace — so a
          mount path or a "writable: true" in that file would mean an agent grants
          itself access by editing Markdown. Everything that decides where a Pocket's
          bytes are, and whether they may be written, lives somewhere the command
          surface cannot reach. The rest of this page is that split, three times over.
        </p>
        <p>
          One more thing a Pocket is not: a program. It holds images, fonts, audio,
          documents. Nothing in it ever runs, which is why it cannot grant itself
          anything.
        </p>
      </div>

      <section class="flex flex-col gap-3" id="explained-pockets-already">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          You have already met three of them
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          This is why the word turns up before you have gone looking for it.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-mono font-bold text-base-content">pockets/backgrounds/</span>
            — the image pool behind
            <.link navigate="/appearance" class="font-semibold text-primary hover:opacity-80">
              Settings → Appearance
            </.link>
            . Uploading a background writes a file here; picking which surface shows it
            is a separate setting.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">pockets/nav-home/</span>
            and its five siblings — <code>nav-workspace</code>, <code>nav-browser</code>, <code>nav-terminal</code>, <code>nav-settings</code>, <code>home-banner</code>. One image each, and that
            image replaces the app's own dock icon or the homepage banner. The shipped
            art stays read-only where it is and renders whenever you have not supplied
            your own.
          </li>
          <li>
            <span class="font-mono font-bold text-base-content">pockets/contact-faces/</span>
            — every WGSL shaderface a contact can wear, in one Pocket rather than one per
            person. A face resolves from the Pocket first and from <code>shaders/</code>
            second, which is why no contact lost its face when this arrived.
          </li>
        </ul>
      </section>

      <.example
        n={1}
        title="Find out what you actually have"
        want="The word keeps appearing. Start by listing what is on disk and what each folder claims to be."
        needs="Nothing. All three pocket_ verbs are safe-tier reads; a workspace with no pockets/ folder yet lists nothing rather than failing."
        touches="Reads directory listings and manifests. Writes nothing, changes no setting, and returns no file bytes."
        confirm="None, and none is needed — the whole pocket_ surface is reads."
        result="Every valid Pocket with its kind, description, roles and file count — and a SEPARATE list of invalid ones, each named with its reason."
      >
        <.prompt text="What Pockets do I have, and what is each one for? If any of them are broken, tell me which and why." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="pocket_list" />
            is the inventory. The field to notice is <code>invalid</code>: a folder whose manifest is missing or malformed is
            reported <span class="font-semibold text-base-content">as broken, not omitted</span>. Skipping it quietly would make a broken folder look
            exactly like a missing one, and you would have no way to tell which you were
            looking at. The Pockets tab draws them the same way — in place, marked
            invalid.
          </li>
          <li>
            <.copy_command command="pocket_describe" />
            opens one in full: every file with its size and whether it is readable as
            text, plus your own prose from under the frontmatter. Ask for that body
            before proposing anything about a Pocket's contents.
          </li>
          <li>
            The refusals are named rather than generic: <code>no_manifest</code>, <code>name_mismatch</code>, <code>invalid_name</code>, <code>unknown_kind</code>, <code>invalid_roles</code>. The last one bites hand-written manifests:
            <code>roles</code>
            is a JSON list, so <code>["background"]</code>
            parses and a bare <code>[background]</code>
            is refused rather than read as a role containing punctuation.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-pockets-roles">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Roles describe a Pocket. They never decide one.
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          A manifest may declare <code>roles</code>
          — <code>background</code>, <code>nav_home</code>, <code>home_banner</code>
          and four more. It is the field most likely to be misread, so it is worth
          being exact about what it does, which is <span class="font-semibold text-base-content">nothing load-bearing</span>.
        </p>
        <p class="text-sm leading-relaxed text-base-content/80">
          Appearance stores the name of its Pocket as the fixed string <code>backgrounds</code>. It does not look up whichever Pocket declares the
          <code>background</code>
          role — even though its own manifest declares exactly that. The reason is the
          failure it prevents:
          <span class="font-semibold text-base-content">
            a malformed or duplicate manifest must never be able to silently relocate
            where your uploads are written.
          </span>
          A discovered binding would mean any folder claiming a role could catch them.
        </p>
        <p class="text-sm leading-relaxed text-base-content/80">
          The dock icons made the same call, and the contact faces show what it is worth:
          faces come from <code>pockets/contact-faces/</code>
          by fixed name, because a role-bound face Pocket would let an agent redirect
          <span class="italic">every</span>
          contact's face at once by writing a manifest into a directory it can already
          write to. A role is a label on a folder. The binding is a constant in the
          code.
        </p>
        <p class="text-sm leading-relaxed text-base-content/70">
          The list of roles is deliberately short — one is added when a surface actually
          asks for it, never in anticipation. A manifest naming a role nothing asks for
          is not an error; it simply stays inert, so a Pocket is never refused for being
          newer than the app reading it.
        </p>
      </section>

      <.example
        n={2}
        title="Hand the agent one file out of a Pocket"
        want="The agent should read the SVG in your icons Pocket — and nothing else on the disk."
        needs="A Pocket that loads. A folder with no POCKET.md is inert: its files can be listed by hand but never read or served."
        touches="Opens exactly one file read-only. Nothing is written, moved or cached."
        confirm="None. The stop here is not a gate, it is a fence: the verb takes a bare filename and cannot express a path."
        result="Text comes back in content, capped at 64 KB with truncated set. A BINARY file succeeds and returns NO bytes — its size and text: false, which is the useful answer. An unlisted file, a symlink, or a Pocket whose manifest is broken all answer not_found."
      >
        <.prompt text="Read claw.svg out of my harbor-icons Pocket and tell me what shapes it draws." />
        <ol class="ic-unfold">
          <li>
            <.copy_command command="pocket_read" />
            goes through one resolver, and every surface that reads a Pocket's bytes goes
            through the same one. It applies four guards, in order, and each defeats a
            different thing: the filename must be a
            <span class="font-semibold text-base-content">bare name</span>
            (no separator, no <code>..</code>, no leading dot, checked before any join, so
            <code>..</code>
            never reaches the filesystem at all); the Pocket's root must be <span class="font-semibold text-base-content">admissible</span>; the joined
            path is canonicalized and re-checked against that root, so a symlink planted
            inside a Pocket cannot escape it; and the result must be a regular file,
            checked in a way that <span class="font-semibold text-base-content">sees a symlink rather than following it</span>.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              The second guard is re-asked on every single call, and nothing is cached.
            </span>
            That is not caution for its own sake — it is what makes the next section's
            off switch immediate rather than eventual.
          </li>
          <li>
            An icon comes back described, not dumped. Bytes that cannot be read as text
            are for a surface that can display them; base64 in a transcript spends your
            context to tell you what a one-line answer already did.
          </li>
        </ol>
      </.example>

      <.example
        n={3}
        title="Point a Pocket at a folder somewhere else on your Mac"
        want="Your font library or your photo exports usable as a Pocket, without copying a gigabyte into the workspace."
        needs="An existing absolute directory, and a human at the machine. This one is not in the prompt box — there is no command for it, at any tier, on purpose."
        touches="Writes ONE app-owned settings row: name, path, writable, and when you did it. Nothing on disk is copied, moved or linked."
        confirm="The act itself is the stop: it is an operator act in the UI. The Writable checkbox is a second, separate one — it is OFF by default, and even when on, an unattended run never gets write."
        result="The Pocket lists that folder's files and is marked with an arrow glyph. Refusals are named: too_broad for / or your home folder, not_found, not_a_directory, app_owned for backgrounds, role_bound for a Pocket a surface is already using."
      >
        <.prompt
          label="What you cannot ask for"
          try_in_chat={false}
          text="Mount my ~/Pictures folder as a Pocket called photos."
        />
        <ol class="ic-unfold">
          <li>
            <span class="font-semibold text-base-content">
              There is no verb for this, and the absence is the design.
            </span>
            The agent may read a mounted Pocket and may never mount one — held in place
            by the shape of the code rather than by a policy check that has to be right.
            You do it yourself: <span class="font-mono font-bold text-base-content">Home → Pockets → Mount…</span>, absolute path, and the
            <span class="font-mono font-bold text-base-content">Writable</span>
            box left alone unless you mean it.
          </li>
          <li>
            <span class="font-semibold text-base-content">Why not just make a symlink?</span>
            Three layers of this app exist specifically to defeat symlinks, and they are
            right to — at the filesystem level there is no difference between the link
            you made on purpose and one somebody planted. A mount does what a symlink
            does and carries the four things a symlink cannot: who, where, whether it may
            be written, and when it happened.
          </li>
          <li>
            <span class="font-semibold text-base-content">
              Read-only by default, and never unattended.
            </span>
            Write takes your explicit grant <span class="italic">and</span>
            a check that a person is actually at a surface. Two checks rather than one,
            for a measured reason: an unattended shift can hold the full API token and
            therefore <span class="italic">present</span>
            as you. While an unattended shift is up, nobody writes a mounted Pocket —
            including you. Coarse on purpose, and reads are untouched.
          </li>
          <li>
            <span class="font-semibold text-base-content">Unmounting deletes nothing.</span>
            It forgets the row, and that asymmetry is why unmounting and deleting a
            Pocket are different words. Because the resolver re-asks on every call and
            holds no cache, the bytes become unreachable <span class="italic">the instant</span>
            the row is gone — not at the next restart.
          </li>
          <li>
            Two Pockets can never be mounted. <code>backgrounds</code>
            is one the app writes into, and it stores its pointers relative to the
            workspace — point it outside and every slot would read as empty, which is the
            state that gets a second image landed on top of your first. The other is any
            Pocket filling a live role: a surface asking for a role expects to write to
            what it gets back. A mounted Pocket never fills a role either way.
          </li>
        </ol>
      </.example>

      <section class="flex flex-col gap-3" id="explained-pockets-wrong">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          When it is wrong, you are shown — never guessed for
        </h3>
        <p class="text-sm leading-relaxed text-base-content/80">
          Three failure states you can actually reach, and the same choice made in all
          three.
        </p>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li>
            <span class="font-semibold text-base-content">A broken manifest</span>
            — the Pocket is listed, in place, marked invalid, with the reason. Not
            skipped, because a skipped folder is indistinguishable from one that is not
            there.
          </li>
          <li>
            <span class="font-semibold text-base-content">Two images in a brand Pocket</span>
            — the dock shows the <span class="italic">text label</span>, not the shipped default and not the
            first file. Picking one would choose for you when the whole reason there is
            an error is that the app cannot know which you meant; falling back to the
            shipped art would look correct and hide a stray file forever. The art
            vanishing is the notification. Remove the extra file, in the app or in
            Finder, and the next render has it back — nothing is stored, so nothing can
            get stuck. Replacing art through the app never deletes the old image either:
            it is moved to the top of your workspace, because you made or chose that
            file.
          </li>
          <li>
            <span class="font-semibold text-base-content">A mount whose folder is gone</span>
            — the Pocket still exists and still describes itself. It simply has no
            contents, and nothing raises on the way to finding that out.
          </li>
        </ul>
      </section>

      <button
        type="button"
        phx-click="select_home_tab"
        phx-value-tab="pockets"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open the Pockets tab
      </button>
    </div>
    """
  end
end
