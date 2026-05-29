defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  Agent adapter that spawns Claude Code in headless mode (`claude -p --output-format stream-json`).
  Implements the same 3-function API as Codex.AppServer so AgentRunner can swap in without changes.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          session_id_agent: pid(),
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

    with {:ok, expanded_workspace} <- validate_workspace(workspace, worker_host) do
      {:ok, agent_pid} = Agent.start_link(fn -> nil end)

      {:ok,
       %{
         session_id_agent: agent_pid,
         workspace: expanded_workspace,
         worker_host: worker_host,
         metadata: %{}
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          session_id_agent: agent_pid,
          workspace: workspace,
          metadata: metadata
        } = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = Agent.get(agent_pid, & &1)

    prompt_path = write_temp_prompt(prompt)

    try do
      command = build_command(session_id, prompt_path)

      case start_port(command, workspace) do
        {:ok, port} ->
          port_pid = port_os_pid(port)
          turn_metadata = Map.put(metadata, :codex_app_server_pid, port_pid)

          emit_message(on_message, :session_started, %{
            session_id: session_id || "pending",
            thread_id: session_id || "pending",
            turn_id: "turn-1"
          }, turn_metadata)

          case stream_turn(port, on_message, agent_pid, turn_metadata) do
            {:ok, _result} ->
              final_session_id = Agent.get(agent_pid, & &1) || session_id || "unknown"

              Logger.info("Claude Code session completed for #{issue_context(issue)} session_id=#{final_session_id}")

              {:ok,
               %{
                 result: :turn_completed,
                 session_id: final_session_id,
                 thread_id: final_session_id,
                 turn_id: "turn-1"
               }}

            {:error, reason} ->
              Logger.warning("Claude Code session ended with error for #{issue_context(issue)}: #{inspect(reason)}")

              emit_message(on_message, :turn_ended_with_error, %{
                session_id: session_id,
                reason: reason
              }, turn_metadata)

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("Failed to start Claude Code for #{issue_context(issue)}: #{inspect(reason)}")
          emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
          {:error, reason}
      end
    after
      cleanup_temp_prompt(prompt_path)
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{session_id_agent: agent_pid}) when is_pid(agent_pid) do
    Agent.stop(agent_pid)
    :ok
  end

  def stop_session(_session), do: :ok

  # --- Port management ---

  defp build_command(session_id, prompt_path) do
    cc_command = Config.settings!().claude_code.command
    base = "#{cc_command} -p --output-format stream-json --verbose --dangerously-skip-permissions"

    resume_flag =
      case session_id do
        id when is_binary(id) and id != "" -> " --resume #{shell_escape(id)}"
        _ -> ""
      end

    "#{base}#{resume_flag} < #{shell_escape(prompt_path)}"
  end

  defp start_port(command, workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      linear_api_key = Config.settings!().tracker.api_key

      env_vars =
        if is_binary(linear_api_key) do
          [{~c"LINEAR_API_KEY", String.to_charlist(linear_api_key)}]
        else
          []
        end

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: env_vars,
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> to_string(os_pid)
      _ -> nil
    end
  end

  # --- JSONL stream processing ---

  defp stream_turn(port, on_message, agent_pid, metadata) do
    timeout_ms = Config.settings!().claude_code.turn_timeout_ms

    receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")
  end

  defp receive_loop(port, on_message, agent_pid, metadata, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, agent_pid, metadata, timeout_ms, complete_line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, :turn_completed}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, agent_pid, metadata, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        handle_init_event(payload, on_message, agent_pid, metadata)
        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:ok, %{"type" => "assistant"} = payload} ->
        usage_metadata = maybe_extract_usage(payload, metadata)

        emit_message(on_message, :notification, %{
          payload: payload,
          raw: line
        }, usage_metadata)

        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:ok, %{"type" => "tool_use"} = payload} ->
        emit_message(on_message, :notification, %{
          payload: payload,
          raw: line
        }, metadata)

        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:ok, %{"type" => "tool_result"} = payload} ->
        emit_message(on_message, :notification, %{
          payload: payload,
          raw: line
        }, metadata)

        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:ok, %{"type" => "result"} = payload} ->
        handle_result_event(payload, line, on_message, agent_pid, metadata)
        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:ok, payload} ->
        emit_message(on_message, :other_message, %{
          payload: payload,
          raw: line
        }, metadata)

        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_line(line)
        receive_loop(port, on_message, agent_pid, metadata, timeout_ms, "")
    end
  end

  defp handle_init_event(payload, on_message, agent_pid, metadata) do
    case Map.get(payload, "session_id") do
      session_id when is_binary(session_id) ->
        Agent.update(agent_pid, fn _ -> session_id end)

        emit_message(on_message, :session_started, %{
          session_id: session_id,
          thread_id: session_id,
          turn_id: "turn-1"
        }, metadata)

      _ ->
        :ok
    end
  end

  defp handle_result_event(payload, raw, on_message, agent_pid, metadata) do
    case Map.get(payload, "session_id") do
      session_id when is_binary(session_id) ->
        Agent.update(agent_pid, fn _ -> session_id end)
      _ ->
        :ok
    end

    usage = Map.get(payload, "usage", %{})
    usage_metadata = Map.put(metadata, :usage, usage)

    emit_message(on_message, :turn_completed, %{
      payload: payload,
      raw: raw,
      details: payload
    }, usage_metadata)
  end

  defp maybe_extract_usage(%{"message" => %{"usage" => usage}}, metadata) when is_map(usage) do
    Map.put(metadata, :usage, usage)
  end

  defp maybe_extract_usage(_payload, metadata), do: metadata

  # --- Helpers ---

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

  defp write_temp_prompt(prompt) do
    path = Path.join(System.tmp_dir!(), "symphony_cc_prompt_#{random_hex(8)}")
    File.write!(path, prompt)
    path
  end

  defp cleanup_temp_prompt(path) do
    File.rm(path)
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

  defp log_non_json_line(line) do
    text =
      line
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code output: #{text}")
      else
        Logger.debug("Claude Code output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
