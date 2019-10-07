defmodule Pleroma.Web.MastodonAPI.AccountView do
  use Pleroma.Web, :view
  alias Pleroma.User
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.MediaProxy

  def render("accounts.json", %{users: users} = opts) do
    render_many(users, AccountView, "account.json", opts)
  end

  def render("account.json", %{user: user}) do
    image = User.avatar_url(user) |> MediaProxy.url()
    header = User.banner_url(user) |> MediaProxy.url()
    user_info = User.user_info(user)

    emojis =
      (user.info["source_data"]["tag"] || [])
      |> Enum.filter(fn %{"type" => t} -> t == "Emoji" end)
      |> Enum.map(fn %{"icon" => %{"url" => url}, "name" => name} ->
        %{
          "shortcode" => String.trim(name, ":"),
          "url" => MediaProxy.url(url),
          "static_url" => MediaProxy.url(url),
          "visible_in_picker" => false
        }
      end)

    %{
      id: to_string(user.id),
      username: username_from_nickname(user.nickname),
      acct: user.nickname,
      display_name: user.name || user.nickname,
      locked: user_info.locked,
      created_at: Utils.to_masto_date(user.inserted_at),
      followers_count: user_info.follower_count,
      following_count: user_info.following_count,
      statuses_count: user_info.note_count,
      note: HtmlSanitizeEx.basic_html(user.bio) || "",
      url: user.ap_id,
      avatar: image,
      avatar_static: image,
      header: header,
      header_static: header,
      emojis: emojis,
      fields: [],
      source: %{
        note: "",
        privacy: user_info.default_scope,
        sensitive: "false"
      }
    }
  end

  def render("mention.json", %{user: user}) do
    %{
      id: to_string(user.id),
      acct: user.nickname,
      username: username_from_nickname(user.nickname),
      url: user.ap_id
    }
  end

  def render("relationship.json", %{user: user, target: target}) do
    %{
      id: to_string(target.id),
      following: User.following?(user, target),
      followed_by: User.following?(target, user),
      blocking: User.blocks?(user, target),
      muting: false,
      requested: false,
      domain_blocking: false
    }
  end

  def render("relationships.json", %{user: user, targets: targets}) do
    render_many(targets, AccountView, "relationship.json", user: user, as: :target)
  end

  defp username_from_nickname(string) when is_binary(string) do
    hd(String.split(string, "@"))
  end

  defp username_from_nickname(_), do: nil
end
