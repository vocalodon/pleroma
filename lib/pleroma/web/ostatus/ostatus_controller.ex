defmodule Pleroma.Web.OStatus.OStatusController do
  use Pleroma.Web, :controller

  alias Pleroma.{User, Activity}
  alias Pleroma.Web.OStatus.{FeedRepresenter, ActivityRepresenter}
  alias Pleroma.Repo
  alias Pleroma.Web.{OStatus, Federator}
  alias Pleroma.Web.XML
  import Ecto.Query

  def feed_redirect(conn, %{"nickname" => nickname}) do
    user = User.get_cached_by_nickname(nickname)

    case get_format(conn) do
      "html" -> Fallback.RedirectController.redirector(conn, nil)
      _ -> redirect conn, external: OStatus.feed_path(user)
    end
  end

  def feed(conn, %{"nickname" => nickname}) do
    user = User.get_cached_by_nickname(nickname)
    query = from activity in Activity,
      where: fragment("?->>'actor' = ?", activity.data, ^user.ap_id),
      limit: 20,
      order_by: [desc: :id]

    activities = query
    |> Repo.all

    response = user
    |> FeedRepresenter.to_simple_form(activities, [user])
    |> :xmerl.export_simple(:xmerl_xml)
    |> to_string

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, response)
  end

  defp decode_or_retry(body) do
    with {:ok, magic_key} <- Pleroma.Web.Salmon.fetch_magic_key(body),
         {:ok, doc} <- Pleroma.Web.Salmon.decode_and_validate(magic_key, body) do
      {:ok, doc}
    else
      _e ->
        with [decoded | _] <- Pleroma.Web.Salmon.decode(body),
             doc <- XML.parse_document(decoded),
             uri when not is_nil(uri) <- XML.string_from_xpath("/entry/author[1]/uri", doc),
             {:ok, _} <- Pleroma.Web.OStatus.make_user(uri, true),
             {:ok, magic_key} <- Pleroma.Web.Salmon.fetch_magic_key(body),
             {:ok, doc} <- Pleroma.Web.Salmon.decode_and_validate(magic_key, body) do
          {:ok, doc}
        end
    end
  end

  def salmon_incoming(conn, _) do
    {:ok, body, _conn} = read_body(conn)
    {:ok, doc} = decode_or_retry(body)

    Federator.enqueue(:incoming_doc, doc)

    conn
    |> send_resp(200, "")
  end

  def object(conn, %{"uuid" => uuid}) do
    with id <- o_status_url(conn, :object, uuid),
         %Activity{} = activity <- Activity.get_create_activity_by_object_ap_id(id),
         %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      case get_format(conn) do
        "html" -> redirect(conn, to: "/notice/#{activity.id}")
        _ -> represent_activity(conn, activity, user)
      end
    end
  end

  def activity(conn, %{"uuid" => uuid}) do
    with id <- o_status_url(conn, :activity, uuid),
         %Activity{} = activity <- Activity.get_by_ap_id(id),
         %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      case get_format(conn) do
        "html" -> redirect(conn, to: "/notice/#{activity.id}")
        _ -> represent_activity(conn, activity, user)
      end
    end
  end

  def notice(conn, %{"id" => id}) do
     with %Activity{} = activity <- Repo.get(Activity, id),
          %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      case get_format(conn) do
        "html" ->
          conn
          |> put_resp_content_type("text/html")
          |> send_file(200, "priv/static/index.html")
        _ -> represent_activity(conn, activity, user)
      end
    end
  end

  defp represent_activity(conn, activity, user) do
    response = activity
    |> ActivityRepresenter.to_simple_form(user, true)
    |> ActivityRepresenter.wrap_with_entry
    |> :xmerl.export_simple(:xmerl_xml)
    |> to_string

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, response)
  end
end
