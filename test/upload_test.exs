defmodule Pleroma.UploadTest do
  alias Pleroma.Upload
  use Pleroma.DataCase

  describe "Storing a file" do
    test "copies the file to the configured folder with deduping" do
      File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

      file = %Plug.Upload{
        content_type: "image/jpg",
        path: Path.absname("test/fixtures/image_tmp.jpg"),
        filename: "an [image.jpg"
      }

      data = Upload.store(file, true)

      assert data["name"] ==
               "e7a6d0cf595bff76f14c9a98b6c199539559e8b844e02e51e5efcfd1f614a2df.jpeg"
    end

    test "copies the file to the configured folder without deduping" do
      File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

      file = %Plug.Upload{
        content_type: "image/jpg",
        path: Path.absname("test/fixtures/image_tmp.jpg"),
        filename: "an [image.jpg"
      }

      data = Upload.store(file, false)
      assert data["name"] == "an [image.jpg"
    end

    test "fixes incorrect content type" do
      File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

      file = %Plug.Upload{
        content_type: "application/octet-stream",
        path: Path.absname("test/fixtures/image_tmp.jpg"),
        filename: "an [image.jpg"
      }

      data = Upload.store(file, true)
      assert hd(data["url"])["mediaType"] == "image/jpeg"
    end

    test "adds missing extension" do
      File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

      file = %Plug.Upload{
        content_type: "image/jpg",
        path: Path.absname("test/fixtures/image_tmp.jpg"),
        filename: "an [image"
      }

      data = Upload.store(file, false)
      assert data["name"] == "an [image.jpg"
    end

    test "fixes incorrect file extension" do
      File.cp!("test/fixtures/image.jpg", "test/fixtures/image_tmp.jpg")

      file = %Plug.Upload{
        content_type: "image/jpg",
        path: Path.absname("test/fixtures/image_tmp.jpg"),
        filename: "an [image.blah"
      }

      data = Upload.store(file, false)
      assert data["name"] == "an [image.jpg"
    end

    test "don't modify filename of an unknown type" do
      File.cp("test/fixtures/test.txt", "test/fixtures/test_tmp.txt")

      file = %Plug.Upload{
        content_type: "text/plain",
        path: Path.absname("test/fixtures/test_tmp.txt"),
        filename: "test.txt"
      }

      data = Upload.store(file, false)
      assert data["name"] == "test.txt"
    end
  end
end
