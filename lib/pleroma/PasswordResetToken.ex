defmodule Pleroma.PasswordResetToken do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.{User, PasswordResetToken, Repo}

  schema "password_reset_tokens" do
    belongs_to(:user, User)
    field(:token, :string)
    field(:used, :boolean, default: false)

    timestamps()
  end

  def create_token(%User{} = user) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64()

    token = %PasswordResetToken{
      user_id: user.id,
      used: false,
      token: token
    }

    Repo.insert(token)
  end

  def used_changeset(struct) do
    struct
    |> cast(%{}, [])
    |> put_change(:used, true)
  end

  def reset_password(token, data) do
    with %{used: false} = token <- Repo.get_by(PasswordResetToken, %{token: token}),
         %User{} = user <- Repo.get(User, token.user_id),
         {:ok, _user} <- User.reset_password(user, data),
         {:ok, token} <- Repo.update(used_changeset(token)) do
      {:ok, token}
    else
      _e -> {:error, token}
    end
  end
end
