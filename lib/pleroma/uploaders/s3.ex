defmodule Pleroma.Uploaders.S3 do
  @behaviour Pleroma.Uploaders.Uploader

  def put_file(name, uuid, path, content_type, _should_dedupe) do
    settings = Application.get_env(:pleroma, Pleroma.Uploaders.S3)
    bucket = Keyword.fetch!(settings, :bucket)
    public_endpoint = Keyword.fetch!(settings, :public_endpoint)

    {:ok, file_data} = File.read(path)

    File.rm!(path)

    s3_name = "#{uuid}/#{name}"

    {:ok, _} =
      ExAws.S3.put_object(bucket, s3_name, file_data, [
        {:acl, :public_read},
        {:content_type, content_type}
      ])
      |> ExAws.request()

    {:ok, "#{public_endpoint}/#{bucket}/#{s3_name}"}
  end
end
