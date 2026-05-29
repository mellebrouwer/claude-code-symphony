defmodule SymphonyElixir.ClaudeCode.AppServerClient do
  @moduledoc """
  Owns one `cc_appserver.py --stdio --no-tcp` child and speaks its
  newline-delimited JSON-RPC 2.0 protocol over a BEAM Port.

  Responsibilities:

    * spawn the Python child over **stdio** (no TCP port is opened) with the
      agent's environment (`LINEAR_API_KEY`) and a per-agent tmux socket;
    * frame the stream — the Port is opened `:binary` and stdout is reassembled
      on `\\n` ourselves, because cc-appserver lines (e.g. `getConversationOutput`
      with large `tool_result`s) can exceed any fixed `line:` cap and would split
      into `:noeol` fragments;
    * correlate responses to requests by JSON-RPC `id`;
    * forward id-less `conversation/*` notifications to a subscriber process as
      `{:cc_appserver_notification, method, params}` (they interleave with
      responses and arrive at any time);
    * on child death, fail every in-flight request with `{:error, :appserver_down}`
      and tell the subscriber `{:cc_appserver_down, reason}` — no silent
      degradation;
    * on shutdown, close the Port and kill **only this agent's** tmux server.

  One client hosts one conversation (one Symphony agent). The adapter starts a
  client per session and links it to the calling `AgentRunner` task, so the
  child's lifetime is bound to the agent's.
  """

  use GenServer
  require Logger

  @type t :: pid()

  defstruct port: nil,
            os_pid: nil,
            socket: nil,
            buffer: "",
            pending: %{},
            next_id: 1,
            subscriber: nil,
            down: nil

  # --- API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Issue a JSON-RPC request and block until the matching response arrives (or the
  child dies / the call times out). Returns `{:ok, result}`, `{:error, rpc_error}`
  (the server's `%{"code" => ..., "message" => ...}` map), `{:error, :timeout}`,
  or `{:error, :appserver_down}`.
  """
  @spec request(t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, map() | atom()}
  def request(client, method, params, timeout) do
    GenServer.call(client, {:request, method, params}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :appserver_down}
  end

  @doc "Route id-less notifications to `pid` as `{:cc_appserver_notification, method, params}`."
  @spec subscribe(t(), pid()) :: :ok
  def subscribe(client, pid), do: GenServer.call(client, {:subscribe, pid})

  @doc "OS pid of the Python child (for dashboards/diagnostics), or nil."
  @spec os_pid(t()) :: String.t() | nil
  def os_pid(client) do
    GenServer.call(client, :os_pid)
  catch
    :exit, _ -> nil
  end

  @spec stop(t()) :: :ok
  def stop(client) do
    GenServer.stop(client, :normal, 10_000)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    python = Keyword.fetch!(opts, :python)
    script = Keyword.fetch!(opts, :script)
    socket = Keyword.fetch!(opts, :tmux_socket)
    workspace = Keyword.fetch!(opts, :workspace)
    claude_bin = Keyword.get(opts, :claude_bin, "claude")
    permission_mode = Keyword.get(opts, :permission_mode, "bypassPermissions")
    env = Keyword.get(opts, :env, [])

    args = [
      script,
      "--stdio",
      "--no-tcp",
      "--tmux-socket",
      socket,
      "--claude-bin",
      claude_bin,
      "--permission-mode",
      permission_mode
    ]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [
          :binary,
          :exit_status,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:cd, String.to_charlist(workspace)},
          {:env, env}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> to_string(pid)
        _ -> nil
      end

    {:ok, %__MODULE__{port: port, os_pid: os_pid, socket: socket}}
  end

  @impl true
  def handle_call({:request, _method, _params}, _from, %{down: down} = state) when not is_nil(down) do
    {:reply, {:error, :appserver_down}, state}
  end

  def handle_call({:request, method, params}, from, state) do
    id = state.next_id
    payload = %{"id" => id, "method" => method, "params" => params}

    try do
      Port.command(state.port, [Jason.encode!(payload), "\n"])
      {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
    catch
      :error, :badarg -> {:reply, {:error, :appserver_down}, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state), do: {:reply, :ok, %{state | subscriber: pid}}
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    {lines, rest} = split_lines(state.buffer <> bytes)
    state = Enum.reduce(lines, %{state | buffer: rest}, &route_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, :normal, mark_down(state, {:exit_status, status})}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, :normal, mark_down(state, {:port_exit, reason})}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # A linked process (the owning AgentRunner task) died — clean up with it so
    # we never leak a tmux server / claude TUI.
    {:stop, :shutdown, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port) != nil, do: safe_close(state.port)
    kill_os_process(state.os_pid)
    kill_tmux_server(state.socket)
    :ok
  end

  # --- framing ---

  # Split a buffer into complete lines plus the trailing (possibly empty)
  # remainder that has not yet been newline-terminated.
  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp route_line("", state), do: state

  defp route_line(line, state) do
    case Jason.decode(line) do
      {:ok, msg} when is_map(msg) -> route_message(msg, state)
      {:ok, _other} -> state
      {:error, _} -> log_non_json(line) && state
    end
  end

  defp route_message(%{"id" => id} = msg, state) when not is_nil(id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        # An id we don't know — there are no server->client requests in this
        # protocol, so just drop it.
        state

      {from, pending} ->
        reply =
          if Map.has_key?(msg, "error"),
            do: {:error, msg["error"]},
            else: {:ok, msg["result"] || %{}}

        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp route_message(%{"method" => method} = msg, state) do
    if state.subscriber do
      send(state.subscriber, {:cc_appserver_notification, method, msg["params"] || %{}})
    end

    state
  end

  defp route_message(_msg, state), do: state

  defp mark_down(state, reason) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :appserver_down})
    if state.subscriber, do: send(state.subscriber, {:cc_appserver_down, reason})
    %{state | pending: %{}, down: reason}
  end

  # --- teardown ---

  defp safe_close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) when is_binary(os_pid) do
    System.cmd("kill", [os_pid], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp kill_tmux_server(nil), do: :ok

  defp kill_tmux_server(socket) when is_binary(socket) do
    System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp log_non_json(line) do
    Logger.debug("cc-appserver non-JSON stdout: #{String.slice(to_string(line), 0, 200)}")
    true
  end
end
