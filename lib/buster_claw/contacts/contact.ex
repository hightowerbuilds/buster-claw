defmodule BusterClaw.Contacts.Contact do
  @moduledoc """
  A person, across both channels: a name, an optional phone, an optional email,
  and a shaderface.

  `face_seed` drives the built-in generative face; `face_shader` (optional) names
  a custom WGSL face in `<workspace>/shaders/`, authored via the shader-designer
  skill and picked by the operator.

  ## There is no `trusted` field, on purpose

  Trust is **derived, never stored** — `BusterClaw.Contacts.trusted?/1` asks the
  markdown policy files, which are the actual gates read by `Google.GmailSync`
  and `Telephony.Drain`. The old `telephony_contacts.trusted` column was read by
  nothing while defaulting to `true`; storing trust here again would recreate a
  switch that can silently disagree with the gate it appears to control. If you
  find yourself wanting to `add :trusted` to this schema, you want
  `Contacts.set_trusted/2` instead — it writes through to the policy file.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias BusterClaw.TrustedNumbers

  schema "contacts" do
    field :name, :string
    field :phone, :string
    field :email, :string
    field :face_shader, :string
    field :face_seed, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:name, :phone, :email, :face_shader, :face_seed])
    |> update_change(:name, &String.trim/1)
    |> blank_to_nil(:phone)
    |> blank_to_nil(:email)
    |> normalize_phone()
    |> normalize_email()
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_reachable()
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be an email address"
    )
    |> put_default_seed()
    |> unique_constraint(:phone)
    |> unique_constraint(:email)
  end

  # A form submits "" for an untouched optional field; "" is not a missing value
  # to Ecto, and an empty string would sail past the unique index as a real
  # duplicate-able value. Collapse it to nil before anything else looks at it.
  defp blank_to_nil(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      value ->
        value
    end)
  end

  # Store E.164 so a contact's phone compares byte-for-byte against both the
  # inbound event's from_number and the trusted-numbers policy, which normalize
  # the same way. TrustedNumbers.normalize/1 is the single definition of that
  # rule — don't re-implement it here, or the two will drift and a contact will
  # look untrusted while its policy entry says otherwise.
  defp normalize_phone(changeset) do
    case get_change(changeset, :phone) do
      nil ->
        changeset

      raw ->
        case TrustedNumbers.normalize(raw) do
          {:ok, e164} ->
            put_change(changeset, :phone, e164)

          :error ->
            add_error(changeset, :phone, "must be a phone number (10 digits, or full +E.164)")
        end
    end
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  # A contact with neither a phone nor an email can never be matched to an
  # inbound event, so it is a note, not a contact.
  defp validate_reachable(changeset) do
    phone = get_field(changeset, :phone)
    email = get_field(changeset, :email)

    if is_nil(phone) and is_nil(email) do
      add_error(changeset, :phone, "a contact needs a phone number or an email address")
    else
      changeset
    end
  end

  # A stable per-contact seed so the generative face is deterministic — the same
  # contact always condenses out of the smoke with the same face. Seeded from
  # whichever identifier exists, phone first.
  defp put_default_seed(changeset) do
    case get_field(changeset, :face_seed) do
      seed when seed in [0, nil] ->
        identifier = get_field(changeset, :phone) || get_field(changeset, :email)

        if is_binary(identifier) do
          put_change(changeset, :face_seed, :erlang.phash2(identifier, 10_000))
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
