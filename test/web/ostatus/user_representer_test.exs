defmodule Pleroma.Web.OStatus.UserRepresenterTest do
  use Pleroma.DataCase
  alias Pleroma.Web.OStatus.UserRepresenter

  import Pleroma.Factory
  alias Pleroma.User

  test "returns a user with id, uri, name and link" do
    user = build(:user, nickname: "レイン")
    tuple = UserRepresenter.to_simple_form(user)

    res = :xmerl.export_simple_content(tuple, :xmerl_xml) |> to_string

    expected = """
    <id>#{user.ap_id}</id>
    <activity:object>http://activitystrea.ms/schema/1.0/person</activity:object>
    <uri>#{user.ap_id}</uri>
    <poco:preferredUsername>#{user.nickname}</poco:preferredUsername>
    <poco:displayName>#{user.name}</poco:displayName>
    <poco:note>#{user.bio}</poco:note>
    <summary>#{user.bio}</summary>
    <name>#{user.nickname}</name>
    <link rel="avatar" href="#{User.avatar_url(user)}" />
    <link rel="header" href="#{User.banner_url(user)}" />
    <ap_enabled>true</ap_enabled>
    """

    assert clean(res) == clean(expected)
  end

  defp clean(string) do
    String.replace(string, ~r/\s/, "")
  end
end
