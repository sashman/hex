defmodule Hex.SCM do
  @moduledoc false

  @behaviour Mix.SCM
  @packages_dir "packages"
  @request_timeout 60_000
  @fetch_timeout @request_timeout * 2

  def fetchable? do
    true
  end

  def format(_opts) do
    "Hex package"
  end

  def format_lock(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, name, version, nil, _managers, _deps] ->
        "#{version} (#{name})"
      [:hex, name, version, <<checksum::binary-8, _::binary>>, _managers, _deps] ->
        "#{version} (#{name}) #{checksum}"
      _ ->
        nil
    end
  end

  def accepts_options(name, opts) do
    Keyword.put_new(opts, :hex, name)
  end

  def checked_out?(opts) do
    File.dir?(opts[:dest])
  end

  def lock_status(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, name, version, checksum, _managers, _deps] ->
        lock_status(opts[:dest], Atom.to_string(name), version, checksum)
      nil ->
        :mismatch
      _ ->
        :outdated
    end
  end

  defp lock_status(dest, name, version, checksum) do
    case File.read(Path.join(dest, ".hex")) do
      {:ok, file} ->
        case parse_manifest(file) do
          {^name, ^version, ^checksum} -> :ok
          {^name, ^version, _} when is_nil(checksum) -> :ok
          {^name, ^version} -> :ok
          _ ->
            :mismatch
        end
      {:error, _} ->
        :mismatch
    end
  end

  def equal?(opts1, opts2) do
    opts1[:hex] == opts2[:hex]
  end

  def managers(opts) do
    case Hex.Utils.lock(opts[:lock]) do
      [:hex, name, version, _checksum, nil, _deps] ->
        Hex.Utils.ensure_registry!(fetch: false)
        name = Atom.to_string(name)
        build_tools = Hex.Registry.get_build_tools(name, version) || []
        Enum.map(build_tools, &String.to_atom/1)
      [:hex, _name, _version, _checksum, managers, _deps] ->
        managers
      _ ->
        []
    end
  after
    Hex.Registry.pdict_clean
  end

  def checkout(opts) do
    Hex.Registry.open!(Hex.Registry.ETS)

    lock = Hex.Utils.lock(opts[:lock]) |> ensure_lock(opts)
    [:hex, _name, version, checksum, _managers, _deps] = lock

    name     = opts[:hex]
    dest     = opts[:dest]
    filename = "#{name}-#{version}.tar"
    path     = cache_path(filename)
    url      = Hex.API.repo_url("tarballs/#{filename}")

    Hex.Shell.info "  Checking package (#{url})"

    case Hex.Parallel.await(:hex_fetcher, {name, version}, @fetch_timeout) do
      {:ok, :cached} ->
        Hex.Shell.info "  Using locally cached package"
      {:ok, :offline} ->
        Hex.Shell.info "  [OFFLINE] Using locally cached package"
      {:ok, :new} ->
        Hex.Shell.info "  Fetched package"
      {:error, reason} ->
        Hex.Shell.error(reason)
        unless File.exists?(path) do
          Mix.raise "Package fetch failed and no cached copy available"
        end
        Hex.Shell.info "  Fetch failed. Using locally cached package"
    end

    File.rm_rf!(dest)
    Hex.Tar.unpack(path, dest, {name, version})
    manifest = encode_manifest(name, version, checksum)
    File.write!(Path.join(dest, ".hex"), manifest)

    opts[:lock]
  after
    Hex.Registry.pdict_clean
  end

  def update(opts) do
    checkout(opts)
  end

  defp ensure_lock(nil, opts) do
    Mix.raise "The lock is missing for package #{opts[:hex]}. This could be " <>
              "because another package has configured the application name " <>
              "for the dependency incorrectly. Verify with the maintainer " <>
              "the parent application"
  end
  defp ensure_lock(lock, _opts), do: lock

  defp parse_manifest(file) do
    file
    |> String.strip
    |> String.split(",")
    |> List.to_tuple
  end

  defp encode_manifest(name, version, checksum) do
    "#{name},#{version},#{checksum}"
  end

  defp cache_path do
    Path.join(Hex.State.fetch!(:home), @packages_dir)
  end

  defp cache_path(name) do
    Path.join([Hex.State.fetch!(:home), @packages_dir, name])
  end

  def prefetch(lock) do
    fetch = fetch_from_lock(lock)

    Enum.each(fetch, fn {name, version} ->
      Hex.Parallel.run(:hex_fetcher, {name, version}, fn ->
        filename = "#{name}-#{version}.tar"
        path = cache_path(filename)
        fetch(filename, path)
      end)
    end)
  end

  defp fetch_from_lock(lock) do
    deps_path = Mix.Project.deps_path

    Enum.flat_map(lock, fn {app, info} ->
      case Hex.Utils.lock(info) do
        [:hex, name, version, _checksum, _managers, _deps] ->
          dest = Path.join(deps_path, "#{app}")
          case lock_status([dest: dest, lock: info]) do
            :ok       -> []
            :mismatch -> [{name, version}]
            :outdated -> [{name, version}]
          end
        _ ->
          []
      end
    end)
  end

  defp fetch(name, path) do
    if Hex.State.fetch!(:offline?) do
      {:ok, :offline}
    else
      etag = Hex.Utils.etag(path)
      url  = Hex.API.repo_url("tarballs/#{name}")
      File.mkdir_p!(cache_path())

      case Hex.Repo.request(url, etag) do
        {:ok, body} when is_binary(body) ->
          File.write!(path, body)
          {:ok, :new}
        other ->
          other
      end
    end
  end
end
