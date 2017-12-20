defmodule Pleroma.Web.TwitterAPI.TwitterAPITest do
  use Pleroma.DataCase
  alias Pleroma.Builders.{UserBuilder, ActivityBuilder}
  alias Pleroma.Web.TwitterAPI.{TwitterAPI, UserView}
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.{Activity, User, Object, Repo}
  alias Pleroma.Web.TwitterAPI.Representers.ActivityRepresenter
  alias Pleroma.Web.ActivityPub.ActivityPub

  import Pleroma.Factory

  test "create a status" do
    user = insert(:user)
    _mentioned_user = UserBuilder.insert(%{nickname: "shp", ap_id: "shp"})

    object_data = %{
      "type" => "Image",
      "url" => [
        %{
          "type" => "Link",
          "mediaType" => "image/jpg",
          "href" => "http://example.org/image.jpg"
        }
      ],
      "uuid" => 1
    }

    object = Repo.insert!(%Object{data: object_data})

    input = %{
      "status" => "Hello again, @shp.<script></script>\nThis is on another :moominmamma: line. #2hu #epic #phantasmagoric",
      "media_ids" => [object.id]
    }

    { :ok, activity = %Activity{} } = TwitterAPI.create_status(user, input)

    assert get_in(activity.data, ["object", "content"]) == "Hello again, <span><a href='shp'>@<span>shp</span></a></span>.&lt;script&gt;&lt;/script&gt;<br>This is on another :moominmamma: line. #2hu #epic #phantasmagoric<br><a href=\"http://example.org/image.jpg\" class='attachment'>image.jpg</a>"
    assert get_in(activity.data, ["object", "type"]) == "Note"
    assert get_in(activity.data, ["object", "actor"]) == user.ap_id
    assert get_in(activity.data, ["actor"]) == user.ap_id
    assert Enum.member?(get_in(activity.data, ["to"]), User.ap_followers(user))
    assert Enum.member?(get_in(activity.data, ["to"]), "https://www.w3.org/ns/activitystreams#Public")
    assert Enum.member?(get_in(activity.data, ["to"]), "shp")
    assert activity.local == true

    assert %{"moominmamma" => "http://localhost:4001/finmoji/128px/moominmamma-128.png"} = activity.data["object"]["emoji"]

    # hashtags
    assert activity.data["object"]["tag"] == ["2hu", "epic", "phantasmagoric"]

    # Add a context
    assert is_binary(get_in(activity.data, ["context"]))
    assert is_binary(get_in(activity.data, ["object", "context"]))

    assert is_list(activity.data["object"]["attachment"])

    assert activity.data["object"] == Object.get_by_ap_id(activity.data["object"]["id"]).data

    user = User.get_by_ap_id(user.ap_id)

    assert user.info["note_count"] == 1
  end

  test "create a status that is a reply" do
    user = insert(:user)
    input = %{
      "status" => "Hello again."
    }

    { :ok, activity = %Activity{} } = TwitterAPI.create_status(user, input)

    input = %{
      "status" => "Here's your (you).",
      "in_reply_to_status_id" => activity.id
    }

    { :ok, reply = %Activity{} } = TwitterAPI.create_status(user, input)

    assert get_in(reply.data, ["context"]) == get_in(activity.data, ["context"])
    assert get_in(reply.data, ["object", "context"]) == get_in(activity.data, ["object", "context"])
    assert get_in(reply.data, ["object", "inReplyTo"]) == get_in(activity.data, ["object", "id"])
    assert get_in(reply.data, ["object", "inReplyToStatusId"]) == activity.id
    assert Enum.member?(get_in(reply.data, ["to"]), user.ap_id)
  end

  test "fetch public statuses, excluding remote ones." do
    %{ public: activity, user: user } = ActivityBuilder.public_and_non_public
    insert(:note_activity, %{local: false})

    follower = insert(:user, following: [User.ap_followers(user)])

    statuses = TwitterAPI.fetch_public_statuses(follower)

    assert length(statuses) == 1
    assert Enum.at(statuses, 0) == ActivityRepresenter.to_map(activity, %{user: user, for: follower})
  end

  test "fetch whole known network statuses" do
    %{ public: activity, user: user } = ActivityBuilder.public_and_non_public
    insert(:note_activity, %{local: false})

    follower = insert(:user, following: [User.ap_followers(user)])

    statuses = TwitterAPI.fetch_public_and_external_statuses(follower)

    assert length(statuses) == 2
    assert Enum.at(statuses, 0) == ActivityRepresenter.to_map(activity, %{user: user, for: follower})
  end

  test "fetch friends' statuses" do
    user = insert(:user, %{following: ["someguy/followers"]})
    {:ok, activity} = ActivityBuilder.insert(%{"to" => ["someguy/followers"]})
    {:ok, direct_activity} = ActivityBuilder.insert(%{"to" => [user.ap_id]})

    statuses = TwitterAPI.fetch_friend_statuses(user)

    activity_user = Repo.get_by(User, ap_id: activity.data["actor"])
    direct_activity_user = Repo.get_by(User, ap_id: direct_activity.data["actor"])

    assert length(statuses) == 2
    assert Enum.at(statuses, 0) == ActivityRepresenter.to_map(activity, %{user: activity_user})
    assert Enum.at(statuses, 1) == ActivityRepresenter.to_map(direct_activity, %{user: direct_activity_user, mentioned: [user]})
  end

  test "fetch user's mentions" do
    user = insert(:user)
    {:ok, activity} = ActivityBuilder.insert(%{"to" => [user.ap_id]})
    activity_user = Repo.get_by(User, ap_id: activity.data["actor"])

    statuses = TwitterAPI.fetch_mentions(user)

    assert length(statuses) == 1
    assert Enum.at(statuses, 0) == ActivityRepresenter.to_map(activity, %{user: activity_user, mentioned: [user]})
  end

  test "get a user by params" do
    user1_result = {:ok, user1} = UserBuilder.insert(%{ap_id: "some id", email: "test@pleroma"})
    {:ok, user2} = UserBuilder.insert(%{ap_id: "some other id", nickname: "testname2", email: "test2@pleroma"})

    assert {:error, "You need to specify screen_name or user_id"} == TwitterAPI.get_user(nil, nil)
    assert user1_result == TwitterAPI.get_user(nil, %{"user_id" => user1.id})
    assert user1_result == TwitterAPI.get_user(nil, %{"user_id" => user1.nickname})
    assert user1_result == TwitterAPI.get_user(nil, %{"screen_name" => user1.nickname})
    assert user1_result == TwitterAPI.get_user(user1, nil)
    assert user1_result == TwitterAPI.get_user(user2, %{"user_id" => user1.id})
    assert user1_result == TwitterAPI.get_user(user2, %{"screen_name" => user1.nickname})
    assert {:error, "No user with such screen_name"} == TwitterAPI.get_user(nil, %{"screen_name" => "Satan"})
    assert {:error, "No user with such user_id"} == TwitterAPI.get_user(nil, %{"user_id" => 666})
  end

  test "fetch user's statuses" do
    {:ok, user1} = UserBuilder.insert(%{ap_id: "some id", email: "test@pleroma"})
    {:ok, user2} = UserBuilder.insert(%{ap_id: "some other id", nickname: "testname2", email: "test2@pleroma"})

    {:ok, status1} = ActivityBuilder.insert(%{"id" => 1}, %{user: user1})
    {:ok, status2} = ActivityBuilder.insert(%{"id" => 2}, %{user: user2})

    user1_statuses = TwitterAPI.fetch_user_statuses(user1, %{"actor_id" => user1.ap_id})

    assert length(user1_statuses) == 1
    assert Enum.at(user1_statuses, 0) == ActivityRepresenter.to_map(status1, %{user: user1})

    user2_statuses = TwitterAPI.fetch_user_statuses(user1, %{"actor_id" => user2.ap_id})

    assert length(user2_statuses) == 1
    assert Enum.at(user2_statuses, 0) == ActivityRepresenter.to_map(status2, %{user: user2})
  end

  test "fetch a single status" do
    {:ok, activity} = ActivityBuilder.insert()
    {:ok, user} = UserBuilder.insert()
    actor = Repo.get_by!(User, ap_id: activity.data["actor"])

    status = TwitterAPI.fetch_status(user, activity.id)

    assert status == ActivityRepresenter.to_map(activity, %{for: user, user: actor})
  end

  test "Follow another user using user_id" do
    user = insert(:user)
    followed = insert(:user)

    {:ok, user, followed, _activity } = TwitterAPI.follow(user, %{"user_id" => followed.id})
    assert User.ap_followers(followed) in user.following

    { :error, msg } = TwitterAPI.follow(user, %{"user_id" => followed.id})
    assert msg == "Could not follow user: #{followed.nickname} is already on your list."
  end

  test "Follow another user using screen_name" do
    user = insert(:user)
    followed = insert(:user)

    {:ok, user, followed, _activity } = TwitterAPI.follow(user, %{"screen_name" => followed.nickname})
    assert User.ap_followers(followed) in user.following

    followed = User.get_by_ap_id(followed.ap_id)
    assert followed.info["follower_count"] == 1

    { :error, msg } = TwitterAPI.follow(user, %{"screen_name" => followed.nickname})
    assert msg == "Could not follow user: #{followed.nickname} is already on your list."
  end

  test "Unfollow another user using user_id" do
    unfollowed = insert(:user)
    user = insert(:user, %{following: [User.ap_followers(unfollowed)]})
    ActivityPub.follow(user, unfollowed)

    {:ok, user, unfollowed } = TwitterAPI.unfollow(user, %{"user_id" => unfollowed.id})
    assert user.following == []

    { :error, msg } = TwitterAPI.unfollow(user, %{"user_id" => unfollowed.id})
    assert msg == "Not subscribed!"
  end

  test "Unfollow another user using screen_name" do
    unfollowed = insert(:user)
    user = insert(:user, %{following: [User.ap_followers(unfollowed)]})

    ActivityPub.follow(user, unfollowed)

    {:ok, user, unfollowed } = TwitterAPI.unfollow(user, %{"screen_name" => unfollowed.nickname})
    assert user.following == []

    { :error, msg } = TwitterAPI.unfollow(user, %{"screen_name" => unfollowed.nickname})
    assert msg == "Not subscribed!"
  end

  test "Block another user using user_id" do
    user = insert(:user)
    blocked = insert(:user)

    {:ok, user, blocked} = TwitterAPI.block(user, %{"user_id" => blocked.id})
    assert User.blocks?(user, blocked)
  end

  test "Block another user using screen_name" do
    user = insert(:user)
    blocked = insert(:user)

    {:ok, user, blocked} = TwitterAPI.block(user, %{"screen_name" => blocked.nickname})
    assert User.blocks?(user, blocked)
  end

  test "Unblock another user using user_id" do
    unblocked = insert(:user)
    user = insert(:user)
    User.block(user, unblocked)

    {:ok, user, unblocked} = TwitterAPI.unblock(user, %{"user_id" => unblocked.id})
    assert user.info["blocks"] == []
  end

  test "Unblock another user using screen_name" do
    unblocked = insert(:user)
    user = insert(:user)
    User.block(user, unblocked)

    {:ok, user, unblocked} = TwitterAPI.unblock(user, %{"screen_name" => unblocked.nickname})
    assert user.info["blocks"] == []
  end

  test "fetch statuses in a context using the conversation id" do
    {:ok, user} = UserBuilder.insert()
    {:ok, activity} = ActivityBuilder.insert(%{"type" => "Create", "context" => "2hu"})
    {:ok, activity_two} = ActivityBuilder.insert(%{"type" => "Create", "context" => "2hu"})
    {:ok, _activity_three} = ActivityBuilder.insert(%{"type" => "Create", "context" => "3hu"})

    {:ok, object} = Object.context_mapping("2hu") |> Repo.insert

    statuses = TwitterAPI.fetch_conversation(user, object.id)

    assert length(statuses) == 2
    assert Enum.at(statuses, 1)["id"] == activity.id
    assert Enum.at(statuses, 0)["id"] == activity_two.id
  end

  test "upload a file" do
    file = %Plug.Upload{content_type: "image/jpg", path: Path.absname("test/fixtures/image.jpg"), filename: "an_image.jpg"}

    response = TwitterAPI.upload(file)

    assert is_binary(response)
  end

  test "it adds user links to an existing text" do
    text = "@gsimg According to @archaeme, that is @daggsy. Also hello @archaeme@archae.me"

    gsimg = insert(:user, %{nickname: "gsimg"})
    archaeme = insert(:user, %{nickname: "archaeme"})
    archaeme_remote = insert(:user, %{nickname: "archaeme@archae.me"})

    mentions = Pleroma.Formatter.parse_mentions(text)
    expected_text = "<span><a href='#{gsimg.ap_id}'>@<span>gsimg</span></a></span> According to <span><a href='#{archaeme.ap_id}'>@<span>archaeme</span></a></span>, that is @daggsy. Also hello <span><a href='#{archaeme_remote.ap_id}'>@<span>archaeme</span></a></span>"

    assert Utils.add_user_links(text, mentions) == expected_text
  end

  test "it favorites a status, returns the updated status" do
    user = insert(:user)
    note_activity = insert(:note_activity)
    activity_user = Repo.get_by!(User, ap_id: note_activity.data["actor"])

    {:ok, status} = TwitterAPI.fav(user, note_activity.id)
    updated_activity = Activity.get_by_ap_id(note_activity.data["id"])

    assert status == ActivityRepresenter.to_map(updated_activity, %{user: activity_user, for: user})
  end

  test "it unfavorites a status, returns the updated status" do
    user = insert(:user)
    note_activity = insert(:note_activity)
    activity_user = Repo.get_by!(User, ap_id: note_activity.data["actor"])
    object = Object.get_by_ap_id(note_activity.data["object"]["id"])

    {:ok, _like_activity, _object } = ActivityPub.like(user, object)
    updated_activity = Activity.get_by_ap_id(note_activity.data["id"])
    assert ActivityRepresenter.to_map(updated_activity, %{user: activity_user, for: user})["fave_num"] == 1

    {:ok, status} = TwitterAPI.unfav(user, note_activity.id)

    assert status["fave_num"] == 0
  end

  test "it retweets a status and returns the retweet" do
    user = insert(:user)
    note_activity = insert(:note_activity)
    activity_user = Repo.get_by!(User, ap_id: note_activity.data["actor"])

    {:ok, status} = TwitterAPI.repeat(user, note_activity.id)
    updated_activity = Activity.get_by_ap_id(note_activity.data["id"])

    assert status == ActivityRepresenter.to_map(updated_activity, %{user: activity_user, for: user})
  end

  test "it registers a new user and returns the user." do
    data = %{
      "nickname" => "lain",
      "email" => "lain@wired.jp",
      "fullname" => "lain iwakura",
      "bio" => "close the world.",
      "password" => "bear",
      "confirm" => "bear"
    }

    {:ok, user} = TwitterAPI.register_user(data)

    fetched_user = Repo.get_by(User, nickname: "lain")
    assert UserView.render("show.json", %{user: user}) == UserView.render("show.json", %{user: fetched_user})
  end

  test "it returns the error on registration problems" do
    data = %{
      "nickname" => "lain",
      "email" => "lain@wired.jp",
      "fullname" => "lain iwakura",
      "bio" => "close the world.",
      "password" => "bear"
    }

    {:error, error_object} = TwitterAPI.register_user(data)

    assert is_binary(error_object[:error])
    refute Repo.get_by(User, nickname: "lain")
  end

  test "it assigns an integer conversation_id" do
    note_activity = insert(:note_activity)
    user = User.get_cached_by_ap_id(note_activity.data["actor"])
    status = ActivityRepresenter.to_map(note_activity, %{user: user})

    assert is_number(status["statusnet_conversation_id"])
  end

  setup do
    Supervisor.terminate_child(Pleroma.Supervisor, Cachex)
    Supervisor.restart_child(Pleroma.Supervisor, Cachex)
    :ok
  end

  describe "context_to_conversation_id" do
    test "creates a mapping object" do
      conversation_id = TwitterAPI.context_to_conversation_id("random context")
      object = Object.get_by_ap_id("random context")

      assert conversation_id == object.id
    end

    test "returns an existing mapping for an existing object" do
      {:ok, object} = Object.context_mapping("random context") |> Repo.insert
      conversation_id = TwitterAPI.context_to_conversation_id("random context")

      assert conversation_id == object.id
    end
  end

  describe "fetching a user by uri" do
    test "fetches a user by uri" do
      id = "https://mastodon.social/users/lambadalambda"
      user = insert(:user)
      {:ok, represented} = TwitterAPI.get_external_profile(user, id)
      remote = User.get_by_ap_id(id)

      assert represented["id"] == UserView.render("show.json", %{user: remote, for: user})["id"]

      # Also fetches the feed.
      assert Activity.get_create_activity_by_object_ap_id("tag:mastodon.social,2017-04-05:objectId=1641750:objectType=Status")
    end
  end
end
