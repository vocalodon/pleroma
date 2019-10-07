defmodule Pleroma.Web.ActivityPub.MRF.RejectNonPublic do
  alias Pleroma.User
  @behaviour Pleroma.Web.ActivityPub.MRF

  @mrf_rejectnonpublic Application.get_env(:pleroma, :mrf_rejectnonpublic)
  @allow_followersonly Keyword.get(@mrf_rejectnonpublic, :allow_followersonly)
  @allow_direct Keyword.get(@mrf_rejectnonpublic, :allow_direct)

  @impl true
  def filter(object) do
    if object["type"] == "Create" do
      user = User.get_cached_by_ap_id(object["actor"])
      public = "https://www.w3.org/ns/activitystreams#Public"

      # Determine visibility
      visibility =
        cond do
          public in object["to"] -> "public"
          public in object["cc"] -> "unlisted"
          user.follower_address in object["to"] -> "followers"
          true -> "direct"
        end

      case visibility do
        "public" ->
          {:ok, object}

        "unlisted" ->
          {:ok, object}

        "followers" ->
          with true <- @allow_followersonly do
            {:ok, object}
          else
            _e -> {:reject, nil}
          end

        "direct" ->
          with true <- @allow_direct do
            {:ok, object}
          else
            _e -> {:reject, nil}
          end
      end
    else
      {:ok, object}
    end
  end
end
