defmodule ContentNetwork.Storage do
  @moduledoc """
  R2/S3 storage interface for the content network.

  Stores articles, reports, email sequences, and other assets.

  Directory structure:
    sites/{domain}/articles/{slug}.md
    sites/{domain}/reports/{type}-{date}.json
    sites/{domain}/emails/{sequence-name}.json
    reports/{type}-{date}.json
  """
  require Logger

  def put_object(key, body, opts \\ []) do
    bucket = get_bucket()
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    Logger.debug("[Storage] PUT #{bucket}/#{key} (#{byte_size(body)} bytes)")

    try do
      result =
        ExAws.S3.put_object(bucket, key, body, content_type: content_type)
        |> ExAws.request()

      case result do
        {:ok, _} ->
          Logger.debug("[Storage] Uploaded #{key}")
          {:ok, key}

        {:error, {:http_error, status, body}} ->
          Logger.warning("[Storage] Upload failed for #{key}: HTTP #{status}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.warning("[Storage] Upload failed for #{key}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("[Storage] Upload exception for #{key}: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  def get_object(key) do
    bucket = get_bucket()

    Logger.debug("[Storage] GET #{bucket}/#{key}")

    try do
      case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
        {:ok, %{body: body}} ->
          {:ok, body}

        {:error, {:http_error, 404, _}} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.warning("[Storage] Get failed for #{key}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("[Storage] Get exception for #{key}: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  def delete_object(key) do
    bucket = get_bucket()

    Logger.debug("[Storage] DELETE #{bucket}/#{key}")

    try do
      case ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
        {:ok, _} -> {:ok, key}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, {:exception, e}}
    end
  end

  def list_objects(prefix, opts \\ []) do
    bucket = get_bucket()
    max_keys = Keyword.get(opts, :max_keys, 1000)

    Logger.debug("[Storage] LIST #{bucket}/#{prefix}")

    try do
      case ExAws.S3.list_objects(bucket, prefix: prefix, max_keys: max_keys) |> ExAws.request() do
        {:ok, %{body: %{contents: contents}}} ->
          keys = Enum.map(contents, & &1.key)
          {:ok, keys}

        {:error, reason} ->
          Logger.warning("[Storage] List failed for #{prefix}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e -> {:error, {:exception, e}}
    end
  end

  def object_exists?(key) do
    case get_object(key) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def get_article_key(domain, slug) do
    "sites/#{domain}/articles/#{slug}.md"
  end

  def get_report_key(domain, type, date \\ nil) do
    date = date || Date.utc_today() |> Date.to_iso8601()
    "sites/#{domain}/reports/#{type}-#{date}.json"
  end

  def get_network_report_key(type, date \\ nil) do
    date = date || Date.utc_today() |> Date.to_iso8601()
    "reports/#{type}-#{date}.json"
  end

  defp get_bucket do
    config = Application.get_env(:content_network, __MODULE__, [])
    Keyword.get(config, :bucket, "content-network-assets")
  end
end
