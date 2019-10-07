defmodule Pleroma.Web.OStatus.OStatusController do
  use Pleroma.Web, :controller

  alias Pleroma.{User, Activity}
  alias Pleroma.Web.OStatus.{FeedRepresenter, ActivityRepresenter}
  alias Pleroma.Repo
  alias Pleroma.Web.{OStatus, Federator}
  alias Pleroma.Web.XML
  alias Pleroma.Web.ActivityPub.ObjectView
  alias Pleroma.Web.ActivityPub.ActivityPubController
  alias Pleroma.Web.ActivityPub.ActivityPub

  action_fallback(:errors)

  def feed_redirect(conn, %{"nickname" => nickname}) do
    case get_format(conn) do
      "html" ->
        Fallback.RedirectController.redirector(conn, nil)

      "activity+json" ->
        ActivityPubController.call(conn, :user)

      _ ->
        with %User{} = user <- User.get_cached_by_nickname(nickname) do
          redirect(conn, external: OStatus.feed_path(user))
        else
          nil -> {:error, :not_found}
        end
    end
  end

  def feed(conn, %{"nickname" => nickname} = params) do
    with %User{} = user <- User.get_cached_by_nickname(nickname) do
      query_params =
        Map.take(params, ["max_id"])
        |> Map.merge(%{"whole_db" => true, "actor_id" => user.ap_id})

      activities =
        ActivityPub.fetch_public_activities(query_params)
        |> Enum.reverse()

      response =
        user
        |> FeedRepresenter.to_simple_form(activities, [user])
        |> :xmerl.export_simple(:xmerl_xml)
        |> to_string

      conn
      |> put_resp_content_type("application/atom+xml")
      |> send_resp(200, response)
    else
      nil -> {:error, :not_found}
    end
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
    if get_format(conn) == "activity+json" do
      ActivityPubController.call(conn, :object)
    else
      with id <- o_status_url(conn, :object, uuid),
           {_, %Activity{} = activity} <-
             {:activity, Activity.get_create_activity_by_object_ap_id(id)},
           {_, true} <- {:public?, ActivityPub.is_public?(activity)},
           %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
        case get_format(conn) do
          "html" -> redirect(conn, to: "/notice/#{activity.id}")
          _ -> represent_activity(conn, nil, activity, user)
        end
      else
        {:public?, false} ->
          {:error, :not_found}

        {:activity, nil} ->
          {:error, :not_found}

        e ->
          e
      end
    end
  end

  def activity(conn, %{"uuid" => uuid}) do
    with id <- o_status_url(conn, :activity, uuid),
         {_, %Activity{} = activity} <- {:activity, Activity.normalize(id)},
         {_, true} <- {:public?, ActivityPub.is_public?(activity)},
         %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      case format = get_format(conn) do
        "html" -> redirect(conn, to: "/notice/#{activity.id}")
        _ -> represent_activity(conn, format, activity, user)
      end
    else
      {:public?, false} ->
        {:error, :not_found}

      {:activity, nil} ->
        {:error, :not_found}

      e ->
        e
    end
  end

  def notice(conn, %{"id" => id}) do
    with {_, %Activity{} = activity} <- {:activity, Repo.get(Activity, id)},
         {_, true} <- {:public?, ActivityPub.is_public?(activity)},
         %User{} = user <- User.get_cached_by_ap_id(activity.data["actor"]) do
      case format = get_format(conn) do
        "html" ->
          conn
          |> put_resp_content_type("text/html")
          |> send_file(200, "priv/static/index.html")

        _ ->
          represent_activity(conn, format, activity, user)
      end
    else
      {:public?, false} ->
        {:error, :not_found}

      {:activity, nil} ->
        {:error, :not_found}

      e ->
        e
    end
  end

  defp represent_activity(conn, "activity+json", activity, user) do
    conn
    |> put_resp_header("content-type", "application/activity+json")
    |> json(ObjectView.render("object.json", %{object: activity}))
  end

  defp represent_activity(conn, _, activity, user) do
    response =
      activity
      |> ActivityRepresenter.to_simple_form(user, true)
      |> ActivityRepresenter.wrap_with_entry()
      |> :xmerl.export_simple(:xmerl_xml)
      |> to_string

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, response)
  end

  def errors(conn, {:error, :not_found}) do
    conn
    |> put_status(404)
    |> text("Not found")
  end

  def errors(conn, _) do
    conn
    |> put_status(500)
    |> text("Something went wrong")
  end
end
