defmodule Pleroma.Web.Streamer do
  use GenServer
  require Logger
  alias Pleroma.{User, Notification, Activity, Object, Repo}
  alias Pleroma.Web.ActivityPub.ActivityPub

  def init(args) do
    {:ok, args}
  end

  def start_link do
    spawn(fn ->
      # 30 seconds
      Process.sleep(1000 * 30)
      GenServer.cast(__MODULE__, %{action: :ping})
    end)

    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def add_socket(topic, socket) do
    GenServer.cast(__MODULE__, %{action: :add, socket: socket, topic: topic})
  end

  def remove_socket(topic, socket) do
    GenServer.cast(__MODULE__, %{action: :remove, socket: socket, topic: topic})
  end

  def stream(topic, item) do
    GenServer.cast(__MODULE__, %{action: :stream, topic: topic, item: item})
  end

  def handle_cast(%{action: :ping}, topics) do
    Map.values(topics)
    |> List.flatten()
    |> Enum.each(fn socket ->
      Logger.debug("Sending keepalive ping")
      send(socket.transport_pid, {:text, ""})
    end)

    spawn(fn ->
      # 30 seconds
      Process.sleep(1000 * 30)
      GenServer.cast(__MODULE__, %{action: :ping})
    end)

    {:noreply, topics}
  end

  def handle_cast(%{action: :stream, topic: "direct", item: item}, topics) do
    recipient_topics =
      User.get_recipients_from_activity(item)
      |> Enum.map(fn %{id: id} -> "direct:#{id}" end)

    Enum.each(recipient_topics || [], fn user_topic ->
      Logger.debug("Trying to push direct message to #{user_topic}\n\n")
      push_to_socket(topics, user_topic, item)
    end)

    {:noreply, topics}
  end

  def handle_cast(%{action: :stream, topic: "list", item: item}, topics) do
    author = User.get_cached_by_ap_id(item.data["actor"])

    # filter the recipient list if the activity is not public, see #270.
    recipient_lists =
      case ActivityPub.is_public?(item) do
        true ->
          Pleroma.List.get_lists_from_activity(item)

        _ ->
          Pleroma.List.get_lists_from_activity(item)
          |> Enum.filter(fn list ->
            owner = Repo.get(User, list.user_id)
            author.follower_address in owner.following
          end)
      end

    recipient_topics =
      recipient_lists
      |> Enum.map(fn %{id: id} -> "list:#{id}" end)

    Enum.each(recipient_topics || [], fn list_topic ->
      Logger.debug("Trying to push message to #{list_topic}\n\n")
      push_to_socket(topics, list_topic, item)
    end)

    {:noreply, topics}
  end

  def handle_cast(%{action: :stream, topic: "user", item: %Notification{} = item}, topics) do
    topic = "user:#{item.user_id}"

    Enum.each(topics[topic] || [], fn socket ->
      json =
        %{
          event: "notification",
          payload:
            Pleroma.Web.MastodonAPI.MastodonAPIController.render_notification(
              socket.assigns["user"],
              item
            )
            |> Jason.encode!()
        }
        |> Jason.encode!()

      send(socket.transport_pid, {:text, json})
    end)

    {:noreply, topics}
  end

  def handle_cast(%{action: :stream, topic: "user", item: item}, topics) do
    Logger.debug("Trying to push to users")

    recipient_topics =
      User.get_recipients_from_activity(item)
      |> Enum.map(fn %{id: id} -> "user:#{id}" end)

    Enum.each(recipient_topics, fn topic ->
      push_to_socket(topics, topic, item)
    end)

    {:noreply, topics}
  end

  def handle_cast(%{action: :stream, topic: topic, item: item}, topics) do
    Logger.debug("Trying to push to #{topic}")
    Logger.debug("Pushing item to #{topic}")
    push_to_socket(topics, topic, item)
    {:noreply, topics}
  end

  def handle_cast(%{action: :add, topic: topic, socket: socket}, sockets) do
    topic = internal_topic(topic, socket)
    sockets_for_topic = sockets[topic] || []
    sockets_for_topic = Enum.uniq([socket | sockets_for_topic])
    sockets = Map.put(sockets, topic, sockets_for_topic)
    Logger.debug("Got new conn for #{topic}")
    {:noreply, sockets}
  end

  def handle_cast(%{action: :remove, topic: topic, socket: socket}, sockets) do
    topic = internal_topic(topic, socket)
    sockets_for_topic = sockets[topic] || []
    sockets_for_topic = List.delete(sockets_for_topic, socket)
    sockets = Map.put(sockets, topic, sockets_for_topic)
    Logger.debug("Removed conn for #{topic}")
    {:noreply, sockets}
  end

  def handle_cast(m, state) do
    Logger.info("Unknown: #{inspect(m)}, #{inspect(state)}")
    {:noreply, state}
  end

  defp represent_update(%Activity{} = activity, %User{} = user) do
    %{
      event: "update",
      payload:
        Pleroma.Web.MastodonAPI.StatusView.render(
          "status.json",
          activity: activity,
          for: user
        )
        |> Jason.encode!()
    }
    |> Jason.encode!()
  end

  def push_to_socket(topics, topic, %Activity{data: %{"type" => "Announce"}} = item) do
    Enum.each(topics[topic] || [], fn socket ->
      # Get the current user so we have up-to-date blocks etc.
      user = User.get_cached_by_ap_id(socket.assigns[:user].ap_id)
      blocks = user.info["blocks"] || []

      parent = Object.normalize(item.data["object"])

      unless is_nil(parent) or item.actor in blocks or parent.data["actor"] in blocks do
        send(socket.transport_pid, {:text, represent_update(item, user)})
      end
    end)
  end

  def push_to_socket(topics, topic, item) do
    Enum.each(topics[topic] || [], fn socket ->
      # Get the current user so we have up-to-date blocks etc.
      user = User.get_cached_by_ap_id(socket.assigns[:user].ap_id)
      blocks = user.info["blocks"] || []

      unless item.actor in blocks do
        send(socket.transport_pid, {:text, represent_update(item, user)})
      end
    end)
  end

  defp internal_topic(topic, socket) when topic in ~w[user direct] do
    "#{topic}:#{socket.assigns[:user].id}"
  end

  defp internal_topic(topic, _), do: topic
end
