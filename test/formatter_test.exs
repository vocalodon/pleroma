defmodule Pleroma.FormatterTest do
  alias Pleroma.Formatter
  use Pleroma.DataCase

  import Pleroma.Factory

  describe ".linkify" do
    test "turning urls into links" do
      text = "Hey, check out https://www.youtube.com/watch?v=8Zg1-TufF%20zY?x=1&y=2#blabla."
      expected = "Hey, check out <a href='https://www.youtube.com/watch?v=8Zg1-TufF%20zY?x=1&y=2#blabla'>https://www.youtube.com/watch?v=8Zg1-TufF%20zY?x=1&y=2#blabla</a>."

      assert Formatter.linkify(text) == expected

      text = "https://mastodon.social/@lambadalambda"
      expected = "<a href='https://mastodon.social/@lambadalambda'>https://mastodon.social/@lambadalambda</a>"

      assert Formatter.linkify(text) == expected

      text = "@lambadalambda"
      expected = "@lambadalambda"

      assert Formatter.linkify(text) == expected

      text = "http://www.cs.vu.nl/~ast/intel/"
      expected = "<a href='http://www.cs.vu.nl/~ast/intel/'>http://www.cs.vu.nl/~ast/intel/</a>"

      assert Formatter.linkify(text) == expected

      text = "https://forum.zdoom.org/viewtopic.php?f=44&t=57087"
      expected = "<a href='https://forum.zdoom.org/viewtopic.php?f=44&t=57087'>https://forum.zdoom.org/viewtopic.php?f=44&t=57087</a>"

      assert Formatter.linkify(text) == expected

      text = "https://en.wikipedia.org/wiki/Sophia_(Gnosticism)#Mythos_of_the_soul"
      expected = "<a href='https://en.wikipedia.org/wiki/Sophia_(Gnosticism)#Mythos_of_the_soul'>https://en.wikipedia.org/wiki/Sophia_(Gnosticism)#Mythos_of_the_soul</a>"

      assert Formatter.linkify(text) == expected
    end
  end

  describe ".parse_tags" do
    test "parses tags in the text" do
      text = "Here's a #Test. Maybe these are #working or not. What about #漢字? And #は｡"
      expected = [
        {"#Test", "test"},
        {"#working", "working"},
        {"#漢字", "漢字"},
        {"#は", "は"}
      ]

      assert Formatter.parse_tags(text) == expected
    end
  end

  test "it can parse mentions and return the relevant users" do
    text = "@gsimg According to @archaeme, that is @daggsy. Also hello @archaeme@archae.me"

    gsimg = insert(:user, %{nickname: "gsimg"})
    archaeme = insert(:user, %{nickname: "archaeme"})
    archaeme_remote = insert(:user, %{nickname: "archaeme@archae.me"})

    expected_result = [
      {"@gsimg", gsimg},
      {"@archaeme", archaeme},
      {"@archaeme@archae.me", archaeme_remote},
    ]

    assert Formatter.parse_mentions(text) == expected_result
  end

  test "it adds cool emoji" do
    text = "I love :moominmamma:"

    expected_result = "I love <img height='32px' width='32px' alt='moominmamma' title='moominmamma' src='/finmoji/128px/moominmamma-128.png' />"

    assert Formatter.emojify(text) == expected_result
  end

  test "it returns the emoji used in the text" do
    text = "I love :moominmamma:"

    assert Formatter.get_emoji(text) == [{"moominmamma", "/finmoji/128px/moominmamma-128.png"}]
  end
end
