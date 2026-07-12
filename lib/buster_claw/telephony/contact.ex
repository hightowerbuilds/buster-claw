defmodule BusterClaw.Telephony.Contact do
  @moduledoc """
  A phone contact: a name for a number, plus the contact's shaderface —
  `face_seed` drives the built-in generative face, and `face_shader`
  (optional) names a custom WGSL face in `<workspace>/shaders/`, authored via
  the shader-designer skill and selected by the operator. `trusted` feeds the
  Phase-2 SMS gate (mirrors the TrustedSenders posture for email).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "telephony_contacts" do
    field :name, :string
    field :number, :string
    field :face_shader, :string
    field :face_seed, :integer, default: 0
    field :trusted, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:name, :number, :face_shader, :face_seed, :trusted])
    |> update_change(:name, &String.trim/1)
    |> normalize_number()
    |> validate_required([:name, :number])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:number, ~r/\A\+?[0-9]{3,15}\z/,
      message: "must be a phone number (digits, optional leading +)"
    )
    |> put_default_seed()
    |> unique_constraint(:number)
  end

  # Accept human-typed numbers — "(503) 555-0142", "503.555.0142" — and store
  # E.164-ish: bare 10-digit NANP gets +1, 11 digits starting 1 gets +.
  defp normalize_number(changeset) do
    update_change(changeset, :number, fn number ->
      digits = String.replace(number || "", ~r/[^0-9+]/, "")

      case digits do
        "+" <> _rest -> digits
        <<_::binary-size(10)>> -> "+1" <> digits
        "1" <> rest when byte_size(rest) == 10 -> "+" <> digits
        other -> other
      end
    end)
  end

  # A stable per-number seed so the generative face is deterministic — the same
  # contact always condenses out of the smoke with the same face.
  defp put_default_seed(changeset) do
    case {get_field(changeset, :face_seed), get_field(changeset, :number)} do
      {0, number} when is_binary(number) ->
        put_change(changeset, :face_seed, :erlang.phash2(number, 10_000))

      _ ->
        changeset
    end
  end
end
