defmodule Pleroma.Web.TwitterAPI.UserViewTest do
  use Pleroma.DataCase

  alias Pleroma.User
  alias Pleroma.Web.TwitterAPI.UserView
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Builders.UserBuilder

  import Pleroma.Factory

  setup do
    user = insert(:user, bio: "<span>Here's some html</span>")
    [user: user]
  end

  test "A user with an avatar object", %{user: user} do
    image = "image"
    user = %{user | avatar: %{"url" => [%{"href" => image}]}}
    represented = UserView.render("show.json", %{user: user})
    assert represented["profile_image_url"] == image
  end

  test "A user with emoji in username", %{user: user} do
    expected =
      "<img height=\"32px\" width=\"32px\" alt=\"karjalanpiirakka\" title=\"karjalanpiirakka\" src=\"/file.png\" /> man"

    user = %{
      user
      | info: %{
          "source_data" => %{
            "tag" => [
              %{
                "type" => "Emoji",
                "icon" => %{"url" => "/file.png"},
                "name" => ":karjalanpiirakka:"
              }
            ]
          }
        }
    }

    user = %{user | name: ":karjalanpiirakka: man"}
    represented = UserView.render("show.json", %{user: user})
    assert represented["name_html"] == expected
  end

  test "A user" do
    note_activity = insert(:note_activity)
    user = User.get_cached_by_ap_id(note_activity.data["actor"])
    {:ok, user} = User.update_note_count(user)
    follower = insert(:user)
    second_follower = insert(:user)

    User.follow(follower, user)
    User.follow(second_follower, user)
    User.follow(user, follower)
    {:ok, user} = User.update_follower_count(user)
    Cachex.put(:user_cache, "user_info:#{user.id}", User.user_info(Repo.get!(User, user.id)))

    image = "http://localhost:4001/images/avi.png"
    banner = "http://localhost:4001/images/banner.png"

    represented = %{
      "id" => user.id,
      "name" => user.name,
      "screen_name" => user.nickname,
      "name_html" => user.name,
      "description" => HtmlSanitizeEx.strip_tags(user.bio |> String.replace("<br>", "\n")),
      "description_html" => HtmlSanitizeEx.basic_html(user.bio),
      "created_at" => user.inserted_at |> Utils.format_naive_asctime(),
      "favourites_count" => 0,
      "statuses_count" => 1,
      "friends_count" => 1,
      "followers_count" => 2,
      "profile_image_url" => image,
      "profile_image_url_https" => image,
      "profile_image_url_profile_size" => image,
      "profile_image_url_original" => image,
      "following" => false,
      "follows_you" => false,
      "statusnet_blocking" => false,
      "rights" => %{
        "delete_others_notice" => false
      },
      "statusnet_profile_url" => user.ap_id,
      "cover_photo" => banner,
      "background_image" => nil,
      "is_local" => true,
      "locked" => false,
      "default_scope" => "public"
    }

    assert represented == UserView.render("show.json", %{user: user})
  end

  test "A user for a given other follower", %{user: user} do
    {:ok, follower} = UserBuilder.insert(%{following: [User.ap_followers(user)]})
    {:ok, user} = User.update_follower_count(user)
    image = "http://localhost:4001/images/avi.png"
    banner = "http://localhost:4001/images/banner.png"

    represented = %{
      "id" => user.id,
      "name" => user.name,
      "screen_name" => user.nickname,
      "name_html" => user.name,
      "description" => HtmlSanitizeEx.strip_tags(user.bio |> String.replace("<br>", "\n")),
      "description_html" => HtmlSanitizeEx.basic_html(user.bio),
      "created_at" => user.inserted_at |> Utils.format_naive_asctime(),
      "favourites_count" => 0,
      "statuses_count" => 0,
      "friends_count" => 0,
      "followers_count" => 1,
      "profile_image_url" => image,
      "profile_image_url_https" => image,
      "profile_image_url_profile_size" => image,
      "profile_image_url_original" => image,
      "following" => true,
      "follows_you" => false,
      "statusnet_blocking" => false,
      "rights" => %{
        "delete_others_notice" => false
      },
      "statusnet_profile_url" => user.ap_id,
      "cover_photo" => banner,
      "background_image" => nil,
      "is_local" => true,
      "locked" => false,
      "default_scope" => "public"
    }

    assert represented == UserView.render("show.json", %{user: user, for: follower})
  end

  test "A user that follows you", %{user: user} do
    follower = insert(:user)
    {:ok, follower} = User.follow(follower, user)
    {:ok, user} = User.update_follower_count(user)
    image = "http://localhost:4001/images/avi.png"
    banner = "http://localhost:4001/images/banner.png"

    represented = %{
      "id" => follower.id,
      "name" => follower.name,
      "screen_name" => follower.nickname,
      "name_html" => follower.name,
      "description" => HtmlSanitizeEx.strip_tags(follower.bio |> String.replace("<br>", "\n")),
      "description_html" => HtmlSanitizeEx.basic_html(follower.bio),
      "created_at" => follower.inserted_at |> Utils.format_naive_asctime(),
      "favourites_count" => 0,
      "statuses_count" => 0,
      "friends_count" => 1,
      "followers_count" => 0,
      "profile_image_url" => image,
      "profile_image_url_https" => image,
      "profile_image_url_profile_size" => image,
      "profile_image_url_original" => image,
      "following" => false,
      "follows_you" => true,
      "statusnet_blocking" => false,
      "rights" => %{
        "delete_others_notice" => false
      },
      "statusnet_profile_url" => follower.ap_id,
      "cover_photo" => banner,
      "background_image" => nil,
      "is_local" => true,
      "locked" => false,
      "default_scope" => "public"
    }

    assert represented == UserView.render("show.json", %{user: follower, for: user})
  end

  test "a user that is a moderator" do
    user = insert(:user, %{info: %{"is_moderator" => true}})
    represented = UserView.render("show.json", %{user: user, for: user})

    assert represented["rights"]["delete_others_notice"]
  end

  test "A blocked user for the blocker" do
    user = insert(:user)
    blocker = insert(:user)
    User.block(blocker, user)
    image = "http://localhost:4001/images/avi.png"
    banner = "http://localhost:4001/images/banner.png"

    represented = %{
      "id" => user.id,
      "name" => user.name,
      "screen_name" => user.nickname,
      "name_html" => user.name,
      "description" => HtmlSanitizeEx.strip_tags(user.bio |> String.replace("<br>", "\n")),
      "description_html" => HtmlSanitizeEx.basic_html(user.bio),
      "created_at" => user.inserted_at |> Utils.format_naive_asctime(),
      "favourites_count" => 0,
      "statuses_count" => 0,
      "friends_count" => 0,
      "followers_count" => 0,
      "profile_image_url" => image,
      "profile_image_url_https" => image,
      "profile_image_url_profile_size" => image,
      "profile_image_url_original" => image,
      "following" => false,
      "follows_you" => false,
      "statusnet_blocking" => true,
      "rights" => %{
        "delete_others_notice" => false
      },
      "statusnet_profile_url" => user.ap_id,
      "cover_photo" => banner,
      "background_image" => nil,
      "is_local" => true,
      "locked" => false,
      "default_scope" => "public"
    }

    blocker = Repo.get(User, blocker.id)
    assert represented == UserView.render("show.json", %{user: user, for: blocker})
  end
end
