defmodule Pleroma.Web.OAuth.Authorization do
  use Ecto.Schema

  alias Pleroma.{User, Repo}
  alias Pleroma.Web.OAuth.{Authorization, App}

  import Ecto.{Changeset}

  schema "oauth_authorizations" do
    field(:token, :string)
    field(:valid_until, :naive_datetime)
    field(:used, :boolean, default: false)
    belongs_to(:user, Pleroma.User)
    belongs_to(:app, App)

    timestamps()
  end

  def create_authorization(%App{} = app, %User{} = user) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64()

    authorization = %Authorization{
      token: token,
      used: false,
      user_id: user.id,
      app_id: app.id,
      valid_until: NaiveDateTime.add(NaiveDateTime.utc_now(), 60 * 10)
    }

    Repo.insert(authorization)
  end

  def use_changeset(%Authorization{} = auth, params) do
    auth
    |> cast(params, [:used])
    |> validate_required([:used])
  end

  def use_token(%Authorization{used: false, valid_until: valid_until} = auth) do
    if NaiveDateTime.diff(NaiveDateTime.utc_now(), valid_until) < 0 do
      Repo.update(use_changeset(auth, %{used: true}))
    else
      {:error, "token expired"}
    end
  end

  def use_token(%Authorization{used: true}), do: {:error, "already used"}
end
