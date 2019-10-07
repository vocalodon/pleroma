defmodule Pleroma.Web.MastodonAPI.AccountViewTest do
  use Pleroma.DataCase
  import Pleroma.Factory
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.User

  test "Represent a user account" do
    source_data = %{
      "tag" => [
        %{
          "type" => "Emoji",
          "icon" => %{"url" => "/file.png"},
          "name" => ":karjalanpiirakka:"
        }
      ]
    }

    user =
      insert(:user, %{
        info: %{"note_count" => 5, "follower_count" => 3, "source_data" => source_data},
        nickname: "shp@shitposter.club",
        name: ":karjalanpiirakka: shp",
        bio: "<script src=\"invalid-html\"></script><span>valid html</span>",
        inserted_at: ~N[2017-08-15 15:47:06.597036]
      })

    expected = %{
      id: to_string(user.id),
      username: "shp",
      acct: user.nickname,
      display_name: user.name,
      locked: false,
      created_at: "2017-08-15T15:47:06.000Z",
      followers_count: 3,
      following_count: 0,
      statuses_count: 5,
      note: "<span>valid html</span>",
      url: user.ap_id,
      avatar: "http://localhost:4001/images/avi.png",
      avatar_static: "http://localhost:4001/images/avi.png",
      header: "http://localhost:4001/images/banner.png",
      header_static: "http://localhost:4001/images/banner.png",
      emojis: [
        %{
          "static_url" => "/file.png",
          "url" => "/file.png",
          "shortcode" => "karjalanpiirakka",
          "visible_in_picker" => false
        }
      ],
      fields: [],
      source: %{
        note: "",
        privacy: "public",
        sensitive: "false"
      }
    }

    assert expected == AccountView.render("account.json", %{user: user})
  end

  test "Represent a smaller mention" do
    user = insert(:user)

    expected = %{
      id: to_string(user.id),
      acct: user.nickname,
      username: user.nickname,
      url: user.ap_id
    }

    assert expected == AccountView.render("mention.json", %{user: user})
  end

  test "represent a relationship" do
    user = insert(:user)
    other_user = insert(:user)

    {:ok, user} = User.follow(user, other_user)
    {:ok, user} = User.block(user, other_user)

    expected = %{
      id: to_string(other_user.id),
      following: false,
      followed_by: false,
      blocking: true,
      muting: false,
      requested: false,
      domain_blocking: false
    }

    assert expected == AccountView.render("relationship.json", %{user: user, target: other_user})
  end
end
