defmodule Pleroma.Web.CommonAPI do
  alias Pleroma.{Repo, Activity, Object, User}
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Formatter

  import Pleroma.Web.CommonAPI.Utils

  def delete(activity_id, user) do
    with %Activity{data: %{"object" => %{"id" => object_id}}} <- Repo.get(Activity, activity_id),
         %Object{} = object <- Object.get_by_ap_id(object_id),
           true <- user.ap_id == object.data["actor"],
         {:ok, delete} <- ActivityPub.delete(object) do
      {:ok, delete}
    end
  end

  def repeat(id_or_ap_id, user) do
    with %Activity{} = activity <- get_by_id_or_ap_id(id_or_ap_id),
         object <- Object.get_by_ap_id(activity.data["object"]["id"]) do
      ActivityPub.announce(user, object)
    else
      _ ->
        {:error, "Could not repeat"}
    end
  end

  def favorite(id_or_ap_id, user) do
    with %Activity{} = activity <- get_by_id_or_ap_id(id_or_ap_id),
         false <- activity.data["actor"] == user.ap_id,
         object <- Object.get_by_ap_id(activity.data["object"]["id"]) do
      ActivityPub.like(user, object)
    else
      _ ->
        {:error, "Could not favorite"}
    end
  end

  def unfavorite(id_or_ap_id, user) do
    with %Activity{} = activity <- get_by_id_or_ap_id(id_or_ap_id),
         false <- activity.data["actor"] == user.ap_id,
         object <- Object.get_by_ap_id(activity.data["object"]["id"]) do
      ActivityPub.unlike(user, object)
    else
      _ ->
        {:error, "Could not unfavorite"}
    end
  end

  @instance Application.get_env(:pleroma, :instance)
  @limit Keyword.get(@instance, :limit)
  def post(user, %{"status" => status} = data) do
    with status <- String.trim(status),
         length when length in 1..@limit <- String.length(status),
         attachments <- attachments_from_ids(data["media_ids"]),
         mentions <- Formatter.parse_mentions(status),
         inReplyTo <- get_replied_to_activity(data["in_reply_to_status_id"]),
         to <- to_for_user_and_mentions(user, mentions, inReplyTo),
         tags <- Formatter.parse_tags(status, data),
         content_html <- make_content_html(status, mentions, attachments, tags, data["no_attachment_links"]),
         context <- make_context(inReplyTo),
         cw <- data["spoiler_text"],
         object <- make_note_data(user.ap_id, to, context, content_html, attachments, inReplyTo, tags, cw),
         object <- Map.put(object, "emoji", Formatter.get_emoji(status) |> Enum.reduce(%{}, fn({name, file}, acc) -> Map.put(acc, name, "#{Pleroma.Web.Endpoint.static_url}#{file}") end)) do
      res = ActivityPub.create(to, user, context, object)
      User.increase_note_count(user)
      res
    end
  end
end
