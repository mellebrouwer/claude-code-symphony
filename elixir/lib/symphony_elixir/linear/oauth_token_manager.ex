defmodule SymphonyElixir.Linear.OAuthTokenManager do
  @moduledoc """
  Manages OAuth app tokens for Linear. Exchanges client credentials on startup
  and refreshes before expiry.
  """

  use Agent
  require Logger

  @token_endpoint "https://api.linear.app/oauth/token"
  @refresh_threshold_seconds 86_400

  defstruct [:access_token, :expires_at, :app_user_id]

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  @spec current_token() :: String.t() | nil
  def current_token do
    Agent.get(__MODULE__, & &1.access_token)
  catch
    :exit, _ -> nil
  end

  @spec app_user_id() :: String.t() | nil
  def app_user_id do
    Agent.get(__MODULE__, & &1.app_user_id)
  catch
    :exit, _ -> nil
  end

  @spec maybe_refresh() :: :ok | {:error, term()}
  def maybe_refresh do
    state = Agent.get(__MODULE__, & &1)

    cond do
      state.access_token == nil ->
        exchange()

      state.expires_at == nil ->
        exchange()

      DateTime.diff(state.expires_at, DateTime.utc_now()) < @refresh_threshold_seconds ->
        Logger.info("OAuth token expires in less than 24 hours, refreshing")
        exchange()

      true ->
        :ok
    end
  catch
    :exit, _ -> {:error, :token_manager_not_running}
  end

  @spec exchange() :: :ok | {:error, term()}
  def exchange do
    case read_credentials() do
      {:ok, client_id, client_secret} ->
        do_exchange(client_id, client_secret)

      {:error, reason} ->
        Logger.warning("OAuth credentials not available: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec credentials_file_path() :: String.t()
  def credentials_file_path do
    Application.get_env(
      :symphony_elixir,
      :linear_oauth_credentials_file,
      default_credentials_path()
    )
  end

  defp default_credentials_path do
    Path.expand("~/.symphony/.linear_oauth.json")
  end

  defp read_credentials do
    path = credentials_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"client_id" => id, "client_secret" => secret}}
          when is_binary(id) and is_binary(secret) and id != "" and secret != "" ->
            {:ok, id, secret}

          {:ok, _} ->
            {:error, :invalid_credentials_format}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end

      {:error, :enoent} ->
        {:error, :credentials_file_not_found}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp do_exchange(client_id, client_secret) do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => client_id,
        "client_secret" => client_secret,
        "actor" => "app",
        "scope" => "read,write"
      })

    case Req.post(@token_endpoint,
           headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
           body: body,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

        app_id = resolve_app_user_id(token)

        Agent.update(__MODULE__, fn _state ->
          %__MODULE__{access_token: token, expires_at: expires_at, app_user_id: app_id}
        end)

        Logger.info("OAuth token obtained, expires at #{expires_at}, app_user_id=#{app_id || "unknown"}")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("OAuth token exchange failed status=#{status}: #{inspect(body)}")
        {:error, {:oauth_exchange_failed, status}}

      {:error, reason} ->
        Logger.error("OAuth token exchange request failed: #{inspect(reason)}")
        {:error, {:oauth_request_failed, reason}}
    end
  end

  defp resolve_app_user_id(token) do
    query = ~s|{"query": "{ viewer { id } }"}|

    case Req.post("https://api.linear.app/graphql",
           headers: [
             {"Authorization", "Bearer #{token}"},
             {"Content-Type", "application/json"}
           ],
           body: query,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => id}}}}} when is_binary(id) ->
        id

      _ ->
        nil
    end
  end
end
