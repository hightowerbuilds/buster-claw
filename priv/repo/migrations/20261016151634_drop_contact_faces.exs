defmodule BusterClaw.Repo.Migrations.DropContactFaces do
  use Ecto.Migration

  # Forward only. The contact-faces stack (a per-contact generative face seed
  # and an optional WGSL face name) had no renderer anywhere in the web layer
  # after the Phone tab left on 10-15. A column nobody reads is a lie the next
  # reader believes — CODE_QUALITY_SWEEP_10-16-26 D2.
  def change do
    alter table(:contacts) do
      remove :face_shader, :string
      remove :face_seed, :integer, default: 0
    end
  end
end
