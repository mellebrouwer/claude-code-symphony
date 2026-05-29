defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  Agent adapter that drives Claude Code through **cc-appserver**: one long-lived
  `cc_appserver.py --stdio --no-tcp` child per agent that keeps an *interactive*
  Claude Code session alive in tmux, driven over newline-delimited JSON-RPC on
  the child's stdin/stdout (a BEAM `Port`).

  This replaces the previous `claude -p --output-format stream-json --resume`
  engine — a cold headless process spawned per turn. Now `start_session` opens a
  persistent conversation, each `run_turn` is a `sendUserMessage` on the same
  `conversationId` (context/caches retained between turns, no `--resume`), and
  `stop_session` closes the conversation and the child.

  The **output contract to the orchestrator is unchanged**: it implements the
  same `run/4`, `start_session/2`, `run_turn/4`, `stop_session/1` API and emits
  the same `on_message` events (`:session_started`, `:notification`,
  `:turn_completed`, `:turn_ended_with_error`, `:other_message`), each carrying
  `:event` + `:timestamp`. Only the input mechanism changed.
  """

  require Logger
  alias SymphonyElixir.ClaudeCode.AppServerClient
  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.Linear.OAuthTokenManager

  # sendUserMessage just acks (waitForCompletion:false) — the turn itself is
  # tracked via notifications, so this only needs to cover the round-trip.
  @ack_timeout_ms 30_000
  @close_timeout_ms 10_000
  @interrupt_timeout_ms 10_000
  # Grace beyond the turn timeout: cc-appserver enforces `timeoutMs` and emits a
  # `turnComplete{timedOut:true}`; our own receive deadline is only a backstop in
  # case that notification never arrives.
  @turn_grace_ms 60_000

  @type session :: %{
          client: pid(),
          conversation_id: String.t(),
          session_id: String.t(),
          tmux_socket: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          metadata: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    cc = Config.settings!().claude_code

    with {:ok, expanded_workspace} <- validate_workspace(workspace, worker_host),
         {:ok, script} <- resolve_app_server_path(cc.app_server_path),
         {:ok, python} <- resolve_python(cc.python_bin) do
      socket = build_tmux_socket(cc.tmux_socket_prefix)

      case AppServerClient.start_link(
             python: python,
             script: script,
             tmux_socket: socket,
             workspace: expanded_workspace,
             claude_bin: cc.command,
             permission_mode: cc.permission_mode,
             env: agent_env()
           ) do
        {:ok, client} ->
          AppServerClient.subscribe(client, self())
          finish_start_session(client, socket, expanded_workspace, worker_host, cc)

        {:error, reason} ->
          {:error, {:app_server_start_failed, reason}}
      end
    end
  end

  defp finish_start_session(client, socket, workspace, worker_host, cc) do
    case open_conversation(client, workspace, cc) do
      {:ok, conversation_id, session_id} ->
        Logger.info("Claude Code conversation opened conversation_id=#{conversation_id} socket=#{socket}")

        {:ok,
         %{
           client: client,
           conversation_id: conversation_id,
           session_id: session_id,
           tmux_socket: socket,
           workspace: workspace,
           worker_host: worker_host,
           metadata: %{}
         }}

      {:error, reason} ->
        AppServerClient.stop(client)
        Logger.error("Failed to open Claude Code conversation: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_conversation(client, workspace, cc) do
    startup = cc.startup_timeout_ms

    with {:ok, _} <-
           AppServerClient.request(
             client,
             "initialize",
             %{"clientInfo" => %{"name" => "symphony-cc", "version" => "1.0"}},
             startup
           ),
         {:ok, result} <-
           AppServerClient.request(
             client,
             "newConversation",
             new_conversation_params(workspace, cc),
             startup
           ) do
      conversation_id = result["conversationId"]
      session_id = result["sessionId"] || conversation_id

      if is_binary(conversation_id) do
        {:ok, conversation_id, session_id}
      else
        {:error, {:invalid_new_conversation_result, result}}
      end
    else
      {:error, reason} -> {:error, {:new_conversation_failed, normalize_error(reason)}}
    end
  end

  defp new_conversation_params(workspace, cc) do
    base = %{"cwd" => workspace, "permissionMode" => cc.permission_mode}

    if is_binary(cc.model) and cc.model != "" do
      Map.put(base, "model", cc.model)
    else
      base
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{client: client, conversation_id: conversation_id, session_id: session_id} = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_timeout = turn_timeout_ms()
    metadata = base_turn_metadata(client)

    # Drop any notifications left over from startup or a previous turn so a stale
    # `conversation/state` / `turnComplete` can't end this turn early.
    drain_notifications()

    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id, thread_id: session_id, turn_id: "turn-1"},
      metadata
    )

    params = %{
      "conversationId" => conversation_id,
      "text" => prompt,
      "waitForCompletion" => false,
      "timeoutMs" => turn_timeout
    }

    case AppServerClient.request(client, "sendUserMessage", params, @ack_timeout_ms) do
      {:ok, _ack} ->
        deadline = System.monotonic_time(:millisecond) + turn_timeout + @turn_grace_ms
        await_turn(client, conversation_id, session_id, on_message, metadata, deadline)

      {:error, reason} ->
        mapped = map_send_error(reason)

        Logger.warning("Claude Code sendUserMessage failed for #{issue_context(issue)}: #{inspect(mapped)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{session_id: session_id, reason: mapped},
          metadata
        )

        {:error, mapped}
    end
  end

  defp await_turn(client, conversation_id, session_id, on_message, metadata, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      handle_turn_timeout(client, conversation_id, session_id, on_message, metadata)
    else
      receive do
        {:cc_appserver_notification, "conversation/turnComplete", %{"conversationId" => ^conversation_id} = params} ->
          handle_turn_complete(params, session_id, on_message, metadata)

        {:cc_appserver_notification, "conversation/item", %{"conversationId" => ^conversation_id, "item" => item}} ->
          emit_message(on_message, :notification, %{payload: item, raw: encode_raw(item)}, metadata)
          await_turn(client, conversation_id, session_id, on_message, metadata, deadline)

        {:cc_appserver_notification, "conversation/state", %{"conversationId" => ^conversation_id, "state" => "dead"}} ->
          Logger.warning("Claude Code session died mid-turn session_id=#{session_id}")

          emit_message(
            on_message,
            :turn_ended_with_error,
            %{session_id: session_id, reason: :conversation_dead},
            metadata
          )

          {:error, :conversation_dead}

        {:cc_appserver_notification, "conversation/state", %{"conversationId" => ^conversation_id} = params} ->
          emit_message(on_message, :other_message, %{payload: params, raw: encode_raw(params)}, metadata)
          await_turn(client, conversation_id, session_id, on_message, metadata, deadline)

        {:cc_appserver_notification, _method, _params} ->
          # Notification for another conversation (shouldn't happen — one
          # conversation per client) or a kind we don't translate.
          await_turn(client, conversation_id, session_id, on_message, metadata, deadline)

        {:cc_appserver_down, reason} ->
          Logger.warning("cc-appserver child went down mid-turn: #{inspect(reason)}")

          emit_message(
            on_message,
            :turn_ended_with_error,
            %{session_id: session_id, reason: {:appserver_down, reason}},
            metadata
          )

          {:error, {:appserver_down, reason}}
      after
        remaining ->
          handle_turn_timeout(client, conversation_id, session_id, on_message, metadata)
      end
    end
  end

  defp handle_turn_complete(params, session_id, on_message, metadata) do
    # Cumulative session usage is what the orchestrator's delta tracker expects
    # (it treats token counts as monotonically increasing absolute totals).
    usage = params["sessionUsage"] || params["usage"] || %{}
    turn_metadata = Map.put(metadata, :usage, usage)

    if params["timedOut"] == true do
      Logger.warning("Claude Code turn timed out session_id=#{session_id}")

      emit_message(
        on_message,
        :turn_ended_with_error,
        %{session_id: session_id, reason: :turn_timeout},
        turn_metadata
      )

      {:error, :turn_timeout}
    else
      emit_message(
        on_message,
        :turn_completed,
        %{payload: params, raw: encode_raw(params), details: params},
        turn_metadata
      )

      Logger.info("Claude Code turn completed session_id=#{session_id}")

      {:ok,
       %{
         result: :turn_completed,
         session_id: session_id,
         thread_id: session_id,
         turn_id: "turn-1"
       }}
    end
  end

  defp handle_turn_timeout(client, conversation_id, session_id, on_message, metadata) do
    Logger.warning("Claude Code turn produced no completion in time session_id=#{session_id}")

    AppServerClient.request(
      client,
      "interruptConversation",
      %{"conversationId" => conversation_id},
      @interrupt_timeout_ms
    )

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, reason: :turn_timeout},
      metadata
    )

    {:error, :turn_timeout}
  end

  @doc """
  Crash recovery for a session whose Claude process died while the cc-appserver
  child is still alive: re-adopts the conversation via interactive `--resume`
  (the tmux/transcript survive). Returns the same session on success.
  """
  @spec resume_session(session()) :: {:ok, session()} | {:error, term()}
  def resume_session(%{client: client, conversation_id: conversation_id} = session)
      when is_pid(client) do
    case AppServerClient.request(
           client,
           "resumeConversation",
           %{"conversationId" => conversation_id},
           startup_timeout_ms()
         ) do
      {:ok, _result} -> {:ok, session}
      {:error, reason} -> {:error, {:resume_failed, normalize_error(reason)}}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{client: client, conversation_id: conversation_id}) when is_pid(client) do
    if Process.alive?(client) do
      # Best-effort: close the conversation (kills its tmux session) then stop
      # the child, whose terminate also kills this agent's tmux server.
      AppServerClient.request(
        client,
        "closeConversation",
        %{"conversationId" => conversation_id, "forget" => true},
        @close_timeout_ms
      )

      AppServerClient.stop(client)
    end

    :ok
  end

  def stop_session(_session), do: :ok

  # --- helpers ---

  defp base_turn_metadata(client) do
    case AppServerClient.os_pid(client) do
      nil -> %{}
      pid -> %{codex_app_server_pid: pid}
    end
  end

  defp drain_notifications do
    receive do
      {:cc_appserver_notification, _method, _params} -> drain_notifications()
    after
      0 -> :ok
    end
  end

  defp resolve_app_server_path(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      {:ok, expanded}
    else
      {:error, {:app_server_not_found, expanded}}
    end
  end

  defp resolve_app_server_path(_path), do: {:error, :app_server_path_not_configured}

  defp resolve_python(bin) when is_binary(bin) and bin != "" do
    case System.find_executable(bin) do
      nil -> {:error, {:python_not_found, bin}}
      path -> {:ok, path}
    end
  end

  defp resolve_python(_bin), do: {:error, :python_not_configured}

  defp build_tmux_socket(prefix) do
    prefix = if is_binary(prefix) and prefix != "", do: prefix, else: "symphony"
    "#{prefix}_#{random_hex(8)}"
  end

  defp agent_env do
    case OAuthTokenManager.current_token() do
      nil ->
        Logger.warning("No OAuth token available for agent — Linear API calls will fail")
        []

      token ->
        [{~c"LINEAR_API_KEY", String.to_charlist("Bearer #{token}")}]
    end
  end

  defp turn_timeout_ms, do: Config.settings!().claude_code.turn_timeout_ms
  defp startup_timeout_ms, do: Config.settings!().claude_code.startup_timeout_ms

  defp map_send_error(%{"code" => -32_002}), do: :conversation_busy
  defp map_send_error(%{"code" => -32_003}), do: :conversation_dead
  defp map_send_error(%{"code" => -32_001}), do: :conversation_not_found
  defp map_send_error(:appserver_down), do: :appserver_down
  defp map_send_error(:timeout), do: :send_timeout
  defp map_send_error(other), do: normalize_error(other)

  defp normalize_error(%{"code" => code, "message" => message}), do: {:rpc_error, code, message}
  defp normalize_error(other), do: other

  defp encode_raw(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      _ -> inspect(map)
    end
  end

  defp validate_workspace(workspace, nil) when is_binary(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.settings!().workspace.root)
    root_prefix = root <> "/"

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical}}

        String.starts_with?(canonical <> "/", canonical_root_prefix) ->
          {:ok, canonical}

        String.starts_with?(expanded <> "/", root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown"

  defp default_on_message(_message), do: :ok
end
