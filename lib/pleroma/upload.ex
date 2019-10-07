defmodule Pleroma.Upload do
  alias Ecto.UUID

  @storage_backend Application.get_env(:pleroma, Pleroma.Upload)
                   |> Keyword.fetch!(:uploader)

  def store(%Plug.Upload{} = file, should_dedupe) do
    content_type = get_content_type(file.path)

    uuid = get_uuid(file, should_dedupe)
    name = get_name(file, uuid, content_type, should_dedupe)

    strip_exif_data(content_type, file.path)

    {:ok, url_path} =
      @storage_backend.put_file(name, uuid, file.path, content_type, should_dedupe)

    %{
      "type" => "Document",
      "url" => [
        %{
          "type" => "Link",
          "mediaType" => content_type,
          "href" => url_path
        }
      ],
      "name" => name
    }
  end

  def store(%{"img" => "data:image/" <> image_data}, should_dedupe) do
    parsed = Regex.named_captures(~r/(?<filetype>jpeg|png|gif);base64,(?<data>.*)/, image_data)
    data = Base.decode64!(parsed["data"], ignore: :whitespace)

    tmp_path = tempfile_for_image(data)

    uuid = UUID.generate()

    content_type = get_content_type(tmp_path)
    strip_exif_data(content_type, tmp_path)

    name =
      create_name(
        String.downcase(Base.encode16(:crypto.hash(:sha256, data))),
        parsed["filetype"],
        content_type
      )

    {:ok, url_path} = @storage_backend.put_file(name, uuid, tmp_path, content_type, should_dedupe)

    %{
      "type" => "Image",
      "url" => [
        %{
          "type" => "Link",
          "mediaType" => content_type,
          "href" => url_path
        }
      ],
      "name" => name
    }
  end

  @doc """
  Creates a tempfile using the Plug.Upload Genserver which cleans them up 
  automatically.
  """
  def tempfile_for_image(data) do
    {:ok, tmp_path} = Plug.Upload.random_file("profile_pics")
    {:ok, tmp_file} = File.open(tmp_path, [:write, :raw, :binary])
    IO.binwrite(tmp_file, data)

    tmp_path
  end

  def strip_exif_data(content_type, file) do
    settings = Application.get_env(:pleroma, Pleroma.Upload)
    do_strip = Keyword.fetch!(settings, :strip_exif)
    [filetype, _ext] = String.split(content_type, "/")

    if filetype == "image" and do_strip == true do
      Mogrify.open(file) |> Mogrify.custom("strip") |> Mogrify.save(in_place: true)
    end
  end

  defp create_name(uuid, ext, type) do
    case type do
      "application/octet-stream" ->
        String.downcase(Enum.join([uuid, ext], "."))

      "audio/mpeg" ->
        String.downcase(Enum.join([uuid, "mp3"], "."))

      _ ->
        String.downcase(Enum.join([uuid, List.last(String.split(type, "/"))], "."))
    end
  end

  defp get_uuid(file, should_dedupe) do
    if should_dedupe do
      Base.encode16(:crypto.hash(:sha256, File.read!(file.path)))
    else
      UUID.generate()
    end
  end

  defp get_name(file, uuid, type, should_dedupe) do
    if should_dedupe do
      create_name(uuid, List.last(String.split(file.filename, ".")), type)
    else
      parts = String.split(file.filename, ".")

      new_filename =
        if length(parts) > 1 do
          Enum.drop(parts, -1) |> Enum.join(".")
        else
          Enum.join(parts)
        end

      case type do
        "application/octet-stream" -> file.filename
        "audio/mpeg" -> new_filename <> ".mp3"
        "image/jpeg" -> new_filename <> ".jpg"
        _ -> Enum.join([new_filename, String.split(type, "/") |> List.last()], ".")
      end
    end
  end

  def get_content_type(file) do
    match =
      File.open(file, [:read], fn f ->
        case IO.binread(f, 8) do
          <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>> ->
            "image/png"

          <<0x47, 0x49, 0x46, 0x38, _, 0x61, _, _>> ->
            "image/gif"

          <<0xFF, 0xD8, 0xFF, _, _, _, _, _>> ->
            "image/jpeg"

          <<0x1A, 0x45, 0xDF, 0xA3, _, _, _, _>> ->
            "video/webm"

          <<0x00, 0x00, 0x00, _, 0x66, 0x74, 0x79, 0x70>> ->
            "video/mp4"

          <<0x49, 0x44, 0x33, _, _, _, _, _>> ->
            "audio/mpeg"

          <<255, 251, _, 68, 0, 0, 0, 0>> ->
            "audio/mpeg"

          <<0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00>> ->
            "audio/ogg"

          <<0x52, 0x49, 0x46, 0x46, _, _, _, _>> ->
            "audio/wav"

          _ ->
            "application/octet-stream"
        end
      end)

    case match do
      {:ok, type} -> type
      _e -> "application/octet-stream"
    end
  end
end
