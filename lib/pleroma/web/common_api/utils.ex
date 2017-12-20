defmodule Pleroma.Web.CommonAPI.Utils do
  alias Pleroma.{Repo, Object, Formatter, User, Activity}
  alias Pleroma.Web.ActivityPub.Utils
  alias Calendar.Strftime

  # This is a hack for twidere.
  def get_by_id_or_ap_id(id) do
    activity = Repo.get(Activity, id) || Activity.get_create_activity_by_object_ap_id(id)
    if activity.data["type"] == "Create" do
      activity
    else
      Activity.get_create_activity_by_object_ap_id(activity.data["object"])
    end
  end

  def get_replied_to_activity(id) when not is_nil(id) do
    Repo.get(Activity, id)
  end
  def get_replied_to_activity(_), do: nil

  def attachments_from_ids(ids) do
    Enum.map(ids || [], fn (media_id) ->
      Repo.get(Object, media_id).data
    end)
  end

  def to_for_user_and_mentions(user, mentions, inReplyTo) do
    default_to = [
      user.follower_address,
      "https://www.w3.org/ns/activitystreams#Public"
    ]

    to = default_to ++ Enum.map(mentions, fn ({_, %{ap_id: ap_id}}) -> ap_id end)
    if inReplyTo do
      Enum.uniq([inReplyTo.data["actor"] | to])
    else
      to
    end
  end

  def make_content_html(status, mentions, attachments, tags, no_attachment_links \\ false) do
    status
    |> format_input(mentions, tags)
    |> maybe_add_attachments(attachments, no_attachment_links)
  end

  def make_context(%Activity{data: %{"context" => context}}), do: context
  def make_context(_), do: Utils.generate_context_id

  def maybe_add_attachments(text, attachments, _no_links = true), do: text
  def maybe_add_attachments(text, attachments, _no_links) do
    add_attachments(text, attachments)
  end
  def add_attachments(text, attachments) do
    attachment_text = Enum.map(attachments, fn
      (%{"url" => [%{"href" => href} | _]}) ->
        name = URI.decode(Path.basename(href))
        "<a href=\"#{href}\" class='attachment'>#{shortname(name)}</a>"
      _ -> ""
    end)
    Enum.join([text | attachment_text], "<br>")
  end

  def format_input(text, mentions, _tags) do
    text
    |> Formatter.html_escape
    |> Formatter.linkify
    |> String.replace("\n", "<br>")
    |> add_user_links(mentions)
    # |> add_tag_links(tags)
  end

  def add_tag_links(text, tags) do
    tags = tags
    |> Enum.sort_by(fn ({tag, _}) -> -String.length(tag) end)

    Enum.reduce(tags, text, fn({full, tag}, text) ->
      url = "#<a href='#{Pleroma.Web.base_url}/tag/#{tag}' rel='tag'>#{tag}</a>"
      String.replace(text, full, url)
    end)
  end

  def add_user_links(text, mentions) do
    mentions = mentions
    |> Enum.sort_by(fn ({name, _}) -> -String.length(name) end)
    |> Enum.map(fn({name, user}) -> {name, user, Ecto.UUID.generate} end)

    # This replaces the mention with a unique reference first so it doesn't
    # contain parts of other replaced mentions. There probably is a better
    # solution for this...
    step_one = mentions
    |> Enum.reduce(text, fn ({match, _user, uuid}, text) ->
      String.replace(text, match, uuid)
    end)

    Enum.reduce(mentions, step_one, fn ({match, %User{ap_id: ap_id}, uuid}, text) ->
      short_match = String.split(match, "@") |> tl() |> hd()
      String.replace(text, uuid, "<span><a href='#{ap_id}'>@<span>#{short_match}</span></a></span>")
    end)
  end

  def make_note_data(actor, to, context, content_html, attachments, inReplyTo, tags, cw \\ nil) do
      object = %{
        "type" => "Note",
        "to" => to,
        "content" => content_html,
        "summary" => cw,
        "context" => context,
        "attachment" => attachments,
        "actor" => actor,
        "tag" => tags |> Enum.map(fn ({_, tag}) -> tag end)
      }

    if inReplyTo do
      object
      |> Map.put("inReplyTo", inReplyTo.data["object"]["id"])
      |> Map.put("inReplyToStatusId", inReplyTo.id)
    else
      object
    end
  end

  def format_naive_asctime(date) do
    date |> DateTime.from_naive!("Etc/UTC") |> format_asctime
  end

  def format_asctime(date) do
    Strftime.strftime!(date, "%a %b %d %H:%M:%S %z %Y")
  end

  def date_to_asctime(date) do
    with {:ok, date, _offset} <- date |> DateTime.from_iso8601 do
      format_asctime(date)
    else _e ->
        ""
    end
  end

  def to_masto_date(%NaiveDateTime{} = date) do
    date
    |> NaiveDateTime.to_iso8601
    |> String.replace(~r/(\.\d+)?$/, ".000Z", global: false)
  end

  def to_masto_date(date) do
    try do
      date
      |> NaiveDateTime.from_iso8601!
      |> NaiveDateTime.to_iso8601
      |> String.replace(~r/(\.\d+)?$/, ".000Z", global: false)
    rescue
      _e -> ""
    end
  end

  defp shortname(name) do
    if String.length(name) < 30 do
      name
    else
      String.slice(name, 0..30) <> "…"
    end
  end
end
