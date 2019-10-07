defmodule Pleroma.Web.ActivityPub.Transmogrifier do
  @moduledoc """
  A module to handle coding from internal to wire ActivityPub and back.
  """
  alias Pleroma.User
  alias Pleroma.Object
  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Utils

  import Ecto.Query

  require Logger

  def get_actor(%{"actor" => actor}) when is_binary(actor) do
    actor
  end

  def get_actor(%{"actor" => actor}) when is_list(actor) do
    if is_binary(Enum.at(actor, 0)) do
      Enum.at(actor, 0)
    else
      Enum.find(actor, fn %{"type" => type} -> type == "Person" end)
      |> Map.get("id")
    end
  end

  def get_actor(%{"actor" => actor}) when is_map(actor) do
    actor["id"]
  end

  @doc """
  Checks that an imported AP object's actor matches the domain it came from.
  """
  def contain_origin(id, %{"actor" => actor} = params) do
    id_uri = URI.parse(id)
    actor_uri = URI.parse(get_actor(params))

    if id_uri.host == actor_uri.host do
      :ok
    else
      :error
    end
  end

  @doc """
  Modifies an incoming AP object (mastodon format) to our internal format.
  """
  def fix_object(object) do
    object
    |> fix_actor
    |> fix_attachments
    |> fix_context
    |> fix_in_reply_to
    |> fix_emoji
    |> fix_tag
    |> fix_content_map
    |> fix_likes
    |> fix_addressing
  end

  def fix_addressing_list(map, field) do
    if is_binary(map[field]) do
      map
      |> Map.put(field, [map[field]])
    else
      map
    end
  end

  def fix_addressing(map) do
    map
    |> fix_addressing_list("to")
    |> fix_addressing_list("cc")
    |> fix_addressing_list("bto")
    |> fix_addressing_list("bcc")
  end

  def fix_actor(%{"attributedTo" => actor} = object) do
    object
    |> Map.put("actor", get_actor(%{"actor" => actor}))
  end

  def fix_likes(%{"likes" => likes} = object)
      when is_bitstring(likes) do
    # Check for standardisation
    # This is what Peertube does
    # curl -H 'Accept: application/activity+json' $likes | jq .totalItems
    object
    |> Map.put("likes", [])
    |> Map.put("like_count", 0)
  end

  def fix_likes(object) do
    object
  end

  def fix_in_reply_to(%{"inReplyTo" => in_reply_to_id} = object)
      when not is_nil(in_reply_to_id) do
    case ActivityPub.fetch_object_from_id(in_reply_to_id) do
      {:ok, replied_object} ->
        with %Activity{} = activity <-
               Activity.get_create_activity_by_object_ap_id(replied_object.data["id"]) do
          object
          |> Map.put("inReplyTo", replied_object.data["id"])
          |> Map.put("inReplyToAtomUri", object["inReplyToAtomUri"] || in_reply_to_id)
          |> Map.put("inReplyToStatusId", activity.id)
          |> Map.put("conversation", replied_object.data["context"] || object["conversation"])
          |> Map.put("context", replied_object.data["context"] || object["conversation"])
        else
          e ->
            Logger.error("Couldn't fetch #{object["inReplyTo"]} #{inspect(e)}")
            object
        end

      e ->
        Logger.error("Couldn't fetch #{object["inReplyTo"]} #{inspect(e)}")
        object
    end
  end

  def fix_in_reply_to(object), do: object

  def fix_context(object) do
    context = object["context"] || object["conversation"] || Utils.generate_context_id()

    object
    |> Map.put("context", context)
    |> Map.put("conversation", context)
  end

  def fix_attachments(object) do
    attachments =
      (object["attachment"] || [])
      |> Enum.map(fn data ->
        url = [%{"type" => "Link", "mediaType" => data["mediaType"], "href" => data["url"]}]
        Map.put(data, "url", url)
      end)

    object
    |> Map.put("attachment", attachments)
  end

  def fix_emoji(object) do
    tags = object["tag"] || []
    emoji = tags |> Enum.filter(fn data -> data["type"] == "Emoji" and data["icon"] end)

    emoji =
      emoji
      |> Enum.reduce(%{}, fn data, mapping ->
        name = data["name"]

        name =
          if String.starts_with?(name, ":") do
            name |> String.slice(1..-2)
          else
            name
          end

        mapping |> Map.put(name, data["icon"]["url"])
      end)

    # we merge mastodon and pleroma emoji into a single mapping, to allow for both wire formats
    emoji = Map.merge(object["emoji"] || %{}, emoji)

    object
    |> Map.put("emoji", emoji)
  end

  def fix_tag(object) do
    tags =
      (object["tag"] || [])
      |> Enum.filter(fn data -> data["type"] == "Hashtag" and data["name"] end)
      |> Enum.map(fn data -> String.slice(data["name"], 1..-1) end)

    combined = (object["tag"] || []) ++ tags

    object
    |> Map.put("tag", combined)
  end

  # content map usually only has one language so this will do for now.
  def fix_content_map(%{"contentMap" => content_map} = object) do
    content_groups = Map.to_list(content_map)
    {_, content} = Enum.at(content_groups, 0)

    object
    |> Map.put("content", content)
  end

  def fix_content_map(object), do: object

  # disallow objects with bogus IDs
  def handle_incoming(%{"id" => nil}), do: :error
  def handle_incoming(%{"id" => ""}), do: :error
  # length of https:// = 8, should validate better, but good enough for now.
  def handle_incoming(%{"id" => id}) when not (is_binary(id) and length(id) > 8), do: :error

  # TODO: validate those with a Ecto scheme
  # - tags
  # - emoji
  def handle_incoming(%{"type" => "Create", "object" => %{"type" => objtype} = object} = data)
      when objtype in ["Article", "Note", "Video"] do
    actor = get_actor(data)

    data =
      Map.put(data, "actor", actor)
      |> fix_addressing

    with nil <- Activity.get_create_activity_by_object_ap_id(object["id"]),
         %User{} = user <- User.get_or_fetch_by_ap_id(data["actor"]) do
      object = fix_object(data["object"])

      params = %{
        to: data["to"],
        object: object,
        actor: user,
        context: object["conversation"],
        local: false,
        published: data["published"],
        additional:
          Map.take(data, [
            "cc",
            "id"
          ])
      }

      ActivityPub.create(params)
    else
      %Activity{} = activity -> {:ok, activity}
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Follow", "object" => followed, "actor" => follower, "id" => id} = data
      ) do
    with %User{local: true} = followed <- User.get_cached_by_ap_id(followed),
         %User{} = follower <- User.get_or_fetch_by_ap_id(follower),
         {:ok, activity} <- ActivityPub.follow(follower, followed, id, false) do
      if not User.locked?(followed) do
        ActivityPub.accept(%{
          to: [follower.ap_id],
          actor: followed.ap_id,
          object: data,
          local: true
        })

        User.follow(follower, followed)
      end

      {:ok, activity}
    else
      _e -> :error
    end
  end

  defp mastodon_follow_hack(%{"id" => id, "actor" => follower_id}, followed) do
    with true <- id =~ "follows",
         %User{local: true} = follower <- User.get_cached_by_ap_id(follower_id),
         %Activity{} = activity <- Utils.fetch_latest_follow(follower, followed) do
      {:ok, activity}
    else
      _ -> {:error, nil}
    end
  end

  defp mastodon_follow_hack(_), do: {:error, nil}

  defp get_follow_activity(follow_object, followed) do
    with object_id when not is_nil(object_id) <- Utils.get_ap_id(follow_object),
         {_, %Activity{} = activity} <- {:activity, Activity.get_by_ap_id(object_id)} do
      {:ok, activity}
    else
      # Can't find the activity. This might a Mastodon 2.3 "Accept"
      {:activity, nil} ->
        mastodon_follow_hack(follow_object, followed)

      _ ->
        {:error, nil}
    end
  end

  def handle_incoming(
        %{"type" => "Accept", "object" => follow_object, "actor" => actor, "id" => id} = data
      ) do
    with %User{} = followed <- User.get_or_fetch_by_ap_id(actor),
         {:ok, follow_activity} <- get_follow_activity(follow_object, followed),
         %User{local: true} = follower <- User.get_cached_by_ap_id(follow_activity.data["actor"]),
         {:ok, activity} <-
           ActivityPub.accept(%{
             to: follow_activity.data["to"],
             type: "Accept",
             actor: followed.ap_id,
             object: follow_activity.data["id"],
             local: false
           }) do
      if not User.following?(follower, followed) do
        {:ok, follower} = User.follow(follower, followed)
      end

      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Reject", "object" => follow_object, "actor" => actor, "id" => id} = data
      ) do
    with %User{} = followed <- User.get_or_fetch_by_ap_id(actor),
         {:ok, follow_activity} <- get_follow_activity(follow_object, followed),
         %User{local: true} = follower <- User.get_cached_by_ap_id(follow_activity.data["actor"]),
         {:ok, activity} <-
           ActivityPub.accept(%{
             to: follow_activity.data["to"],
             type: "Accept",
             actor: followed.ap_id,
             object: follow_activity.data["id"],
             local: false
           }) do
      User.unfollow(follower, followed)

      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Like", "object" => object_id, "actor" => actor, "id" => id} = _data
      ) do
    with %User{} = actor <- User.get_or_fetch_by_ap_id(actor),
         {:ok, object} <-
           get_obj_helper(object_id) || ActivityPub.fetch_object_from_id(object_id),
         {:ok, activity, _object} <- ActivityPub.like(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Announce", "object" => object_id, "actor" => actor, "id" => id} = _data
      ) do
    with %User{} = actor <- User.get_or_fetch_by_ap_id(actor),
         {:ok, object} <-
           get_obj_helper(object_id) || ActivityPub.fetch_object_from_id(object_id),
         {:ok, activity, _object} <- ActivityPub.announce(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Update", "object" => %{"type" => "Person"} = object, "actor" => actor_id} =
          data
      ) do
    with %User{ap_id: ^actor_id} = actor <- User.get_by_ap_id(object["id"]) do
      {:ok, new_user_data} = ActivityPub.user_data_from_user_object(object)

      banner = new_user_data[:info]["banner"]
      locked = new_user_data[:info]["locked"] || false

      update_data =
        new_user_data
        |> Map.take([:name, :bio, :avatar])
        |> Map.put(:info, Map.merge(actor.info, %{"banner" => banner, "locked" => locked}))

      actor
      |> User.upgrade_changeset(update_data)
      |> User.update_and_set_cache()

      ActivityPub.update(%{
        local: false,
        to: data["to"] || [],
        cc: data["cc"] || [],
        object: object,
        actor: actor_id
      })
    else
      e ->
        Logger.error(e)
        :error
    end
  end

  # TODO: Make secure.
  def handle_incoming(
        %{"type" => "Delete", "object" => object_id, "actor" => actor, "id" => _id} = _data
      ) do
    object_id = Utils.get_ap_id(object_id)

    with %User{} = _actor <- User.get_or_fetch_by_ap_id(actor),
         {:ok, object} <-
           get_obj_helper(object_id) || ActivityPub.fetch_object_from_id(object_id),
         {:ok, activity} <- ActivityPub.delete(object, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Announce", "object" => object_id},
          "actor" => actor,
          "id" => id
        } = _data
      ) do
    with %User{} = actor <- User.get_or_fetch_by_ap_id(actor),
         {:ok, object} <-
           get_obj_helper(object_id) || ActivityPub.fetch_object_from_id(object_id),
         {:ok, activity, _} <- ActivityPub.unannounce(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Follow", "object" => followed},
          "actor" => follower,
          "id" => id
        } = _data
      ) do
    with %User{local: true} = followed <- User.get_cached_by_ap_id(followed),
         %User{} = follower <- User.get_or_fetch_by_ap_id(follower),
         {:ok, activity} <- ActivityPub.unfollow(follower, followed, id, false) do
      User.unfollow(follower, followed)
      {:ok, activity}
    else
      e -> :error
    end
  end

  @ap_config Application.get_env(:pleroma, :activitypub)
  @accept_blocks Keyword.get(@ap_config, :accept_blocks)

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Block", "object" => blocked},
          "actor" => blocker,
          "id" => id
        } = _data
      ) do
    with true <- @accept_blocks,
         %User{local: true} = blocked <- User.get_cached_by_ap_id(blocked),
         %User{} = blocker <- User.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <- ActivityPub.unblock(blocker, blocked, id, false) do
      User.unblock(blocker, blocked)
      {:ok, activity}
    else
      e -> :error
    end
  end

  def handle_incoming(
        %{"type" => "Block", "object" => blocked, "actor" => blocker, "id" => id} = data
      ) do
    with true <- @accept_blocks,
         %User{local: true} = blocked = User.get_cached_by_ap_id(blocked),
         %User{} = blocker = User.get_or_fetch_by_ap_id(blocker),
         {:ok, activity} <- ActivityPub.block(blocker, blocked, id, false) do
      User.unfollow(blocker, blocked)
      User.block(blocker, blocked)
      {:ok, activity}
    else
      e -> :error
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Like", "object" => object_id},
          "actor" => actor,
          "id" => id
        } = _data
      ) do
    with %User{} = actor <- User.get_or_fetch_by_ap_id(actor),
         {:ok, object} <-
           get_obj_helper(object_id) || ActivityPub.fetch_object_from_id(object_id),
         {:ok, activity, _, _} <- ActivityPub.unlike(actor, object, id, false) do
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(_), do: :error

  def get_obj_helper(id) do
    if object = Object.normalize(id), do: {:ok, object}, else: nil
  end

  def set_reply_to_uri(%{"inReplyTo" => inReplyTo} = object) do
    with false <- String.starts_with?(inReplyTo, "http"),
         {:ok, %{data: replied_to_object}} <- get_obj_helper(inReplyTo) do
      Map.put(object, "inReplyTo", replied_to_object["external_url"] || inReplyTo)
    else
      _e -> object
    end
  end

  def set_reply_to_uri(obj), do: obj

  # Prepares the object of an outgoing create activity.
  def prepare_object(object) do
    object
    |> set_sensitive
    |> add_hashtags
    |> add_mention_tags
    |> add_emoji_tags
    |> add_attributed_to
    |> prepare_attachments
    |> set_conversation
    |> set_reply_to_uri
  end

  #  @doc
  #  """
  #  internal -> Mastodon
  #  """

  def prepare_outgoing(%{"type" => "Create", "object" => %{"type" => "Note"} = object} = data) do
    object =
      object
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

    {:ok, data}
  end

  # Mastodon Accept/Reject requires a non-normalized object containing the actor URIs,
  # because of course it does.
  def prepare_outgoing(%{"type" => "Accept"} = data) do
    with follow_activity <- Activity.normalize(data["object"]) do
      object = %{
        "actor" => follow_activity.actor,
        "object" => follow_activity.data["object"],
        "id" => follow_activity.data["id"],
        "type" => "Follow"
      }

      data =
        data
        |> Map.put("object", object)
        |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

      {:ok, data}
    end
  end

  def prepare_outgoing(%{"type" => "Reject"} = data) do
    with follow_activity <- Activity.normalize(data["object"]) do
      object = %{
        "actor" => follow_activity.actor,
        "object" => follow_activity.data["object"],
        "id" => follow_activity.data["id"],
        "type" => "Follow"
      }

      data =
        data
        |> Map.put("object", object)
        |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

      {:ok, data}
    end
  end

  def prepare_outgoing(%{"type" => _type} = data) do
    data =
      data
      |> maybe_fix_object_url
      |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

    {:ok, data}
  end

  def maybe_fix_object_url(data) do
    if is_binary(data["object"]) and not String.starts_with?(data["object"], "http") do
      case ActivityPub.fetch_object_from_id(data["object"]) do
        {:ok, relative_object} ->
          if relative_object.data["external_url"] do
            _data =
              data
              |> Map.put("object", relative_object.data["external_url"])
          else
            data
          end

        e ->
          Logger.error("Couldn't fetch #{data["object"]} #{inspect(e)}")
          data
      end
    else
      data
    end
  end

  def add_hashtags(object) do
    tags =
      (object["tag"] || [])
      |> Enum.map(fn tag ->
        %{
          "href" => Pleroma.Web.Endpoint.url() <> "/tags/#{tag}",
          "name" => "##{tag}",
          "type" => "Hashtag"
        }
      end)

    object
    |> Map.put("tag", tags)
  end

  def add_mention_tags(object) do
    recipients = object["to"] ++ (object["cc"] || [])

    mentions =
      recipients
      |> Enum.map(fn ap_id -> User.get_cached_by_ap_id(ap_id) end)
      |> Enum.filter(& &1)
      |> Enum.map(fn user ->
        %{"type" => "Mention", "href" => user.ap_id, "name" => "@#{user.nickname}"}
      end)

    tags = object["tag"] || []

    object
    |> Map.put("tag", tags ++ mentions)
  end

  # TODO: we should probably send mtime instead of unix epoch time for updated
  def add_emoji_tags(object) do
    tags = object["tag"] || []
    emoji = object["emoji"] || []

    out =
      emoji
      |> Enum.map(fn {name, url} ->
        %{
          "icon" => %{"url" => url, "type" => "Image"},
          "name" => ":" <> name <> ":",
          "type" => "Emoji",
          "updated" => "1970-01-01T00:00:00Z",
          "id" => url
        }
      end)

    object
    |> Map.put("tag", tags ++ out)
  end

  def set_conversation(object) do
    Map.put(object, "conversation", object["context"])
  end

  def set_sensitive(object) do
    tags = object["tag"] || []
    Map.put(object, "sensitive", "nsfw" in tags)
  end

  def add_attributed_to(object) do
    attributedTo = object["attributedTo"] || object["actor"]

    object
    |> Map.put("attributedTo", attributedTo)
  end

  def prepare_attachments(object) do
    attachments =
      (object["attachment"] || [])
      |> Enum.map(fn data ->
        [%{"mediaType" => media_type, "href" => href} | _] = data["url"]
        %{"url" => href, "mediaType" => media_type, "name" => data["name"], "type" => "Document"}
      end)

    object
    |> Map.put("attachment", attachments)
  end

  defp user_upgrade_task(user) do
    old_follower_address = User.ap_followers(user)

    q =
      from(
        u in User,
        where: ^old_follower_address in u.following,
        update: [
          set: [
            following:
              fragment(
                "array_replace(?,?,?)",
                u.following,
                ^old_follower_address,
                ^user.follower_address
              )
          ]
        ]
      )

    Repo.update_all(q, [])

    maybe_retire_websub(user.ap_id)

    # Only do this for recent activties, don't go through the whole db.
    # Only look at the last 1000 activities.
    since = (Repo.aggregate(Activity, :max, :id) || 0) - 1_000

    q =
      from(
        a in Activity,
        where: ^old_follower_address in a.recipients,
        where: a.id > ^since,
        update: [
          set: [
            recipients:
              fragment(
                "array_replace(?,?,?)",
                a.recipients,
                ^old_follower_address,
                ^user.follower_address
              )
          ]
        ]
      )

    Repo.update_all(q, [])
  end

  def upgrade_user_from_ap_id(ap_id, async \\ true) do
    with %User{local: false} = user <- User.get_by_ap_id(ap_id),
         {:ok, data} <- ActivityPub.fetch_and_prepare_user_from_ap_id(ap_id) do
      data =
        data
        |> Map.put(:info, Map.merge(user.info, data[:info]))

      already_ap = User.ap_enabled?(user)

      {:ok, user} =
        User.upgrade_changeset(user, data)
        |> Repo.update()

      if !already_ap do
        # This could potentially take a long time, do it in the background
        if async do
          Task.start(fn ->
            user_upgrade_task(user)
          end)
        else
          user_upgrade_task(user)
        end
      end

      {:ok, user}
    else
      e -> e
    end
  end

  def maybe_retire_websub(ap_id) do
    # some sanity checks
    if is_binary(ap_id) && String.length(ap_id) > 8 do
      q =
        from(
          ws in Pleroma.Web.Websub.WebsubClientSubscription,
          where: fragment("? like ?", ws.topic, ^"#{ap_id}%")
        )

      Repo.delete_all(q)
    end
  end

  def maybe_fix_user_url(data) do
    if is_map(data["url"]) do
      Map.put(data, "url", data["url"]["href"])
    else
      data
    end
  end

  def maybe_fix_user_object(data) do
    data
    |> maybe_fix_user_url
  end
end
