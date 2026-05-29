defmodule SymphonyElixir.ClaudeCode.AdapterTest do
  @moduledoc """
  End-to-end tests for the cc-appserver-backed adapter, run against a real
  `claude` binary. Tagged `:live` (slow, token-costing) — excluded by default;
  run with `mix test --include live`.
  """
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 300_000

  alias SymphonyElixir.ClaudeCode.{Adapter, AppServerClient}

  setup do
    workspace_root = Path.join(System.tmp_dir!(), "symphony_cc_live_workspaces")
    workspace = Path.join(workspace_root, "issue-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspace)

    workflow_path =
      Path.join(System.tmp_dir!(), "symphony_cc_live_workflow_#{:rand.uniform(1_000_000)}.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: memory
      active_states:
        - Todo
      terminal_states:
        - Done
    claude_code:
      command: claude
      model: sonnet
      turn_timeout_ms: 240000
      startup_timeout_ms: 90000
    workspace:
      root: #{workspace_root}
    ---
    Test prompt: {{ issue.title }}
    """)

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    on_exit(fn ->
      SymphonyElixir.Workflow.clear_workflow_file_path()
      File.rm(workflow_path)
      File.rm_rf(workspace)
    end)

    canonical =
      case SymphonyElixir.PathSafety.canonicalize(Path.expand(workspace)) do
        {:ok, p} -> p
        _ -> workspace
      end

    issue = %SymphonyElixir.Linear.Issue{
      id: "live-1",
      identifier: "LIVE-1",
      title: "Live cc-appserver test",
      state: "Todo"
    }

    %{workspace: canonical, issue: issue}
  end

  # An on_message callback that ships every event to the test process so we can
  # assert on it after the (synchronous) turn returns.
  defp collector do
    test = self()
    fn msg -> send(test, {:event, msg}) end
  end

  defp collected_events(acc \\ []) do
    receive do
      {:event, msg} -> collected_events([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tmux_session(conversation_id), do: "ccas_#{String.slice(conversation_id, 0, 8)}"

  test "single turn: 2+2 → 4 with token usage surfaced", %{workspace: ws, issue: issue} do
    {:ok, session} = Adapter.start_session(ws)

    try do
      assert {:ok, turn} =
               Adapter.run_turn(
                 session,
                 "What is 2+2? Reply with only the number.",
                 issue,
                 on_message: collector()
               )

      assert turn.result == :turn_completed
      assert is_binary(turn.session_id)

      events = collected_events()
      assert Enum.any?(events, &(&1.event == :session_started))

      completed = Enum.find(events, &(&1.event == :turn_completed))
      assert completed, "expected a :turn_completed event"
      assert completed.payload["reply"] =~ "4"
      # Usage is the cumulative sessionUsage — the orchestrator's delta tracker
      # relies on it being a monotonic absolute total.
      assert completed.usage["total_tokens"] > 0
    after
      Adapter.stop_session(session)
    end
  end

  test "context continuity across turns (persistent session, no --resume)", %{
    workspace: ws,
    issue: issue
  } do
    {:ok, session} = Adapter.start_session(ws)

    try do
      {:ok, _} = Adapter.run_turn(session, "Remember the number 7. Just acknowledge.", issue)

      {:ok, _} =
        Adapter.run_turn(
          session,
          "What number did I ask you to remember? Reply with only the number.",
          issue,
          on_message: collector()
        )

      completed = collected_events() |> Enum.find(&(&1.event == :turn_completed))
      assert completed.payload["reply"] =~ "7"
    after
      Adapter.stop_session(session)
    end
  end

  test "real work: the agent edits a file in the workspace", %{workspace: ws, issue: issue} do
    {:ok, session} = Adapter.start_session(ws)

    try do
      {:ok, _} =
        Adapter.run_turn(
          session,
          "Create a file named result.txt in the current directory whose entire " <>
            "contents are exactly: symphony-ok",
          issue
        )

      path = Path.join(ws, "result.txt")
      assert File.exists?(path), "expected the agent to create result.txt"
      assert File.read!(path) =~ "symphony-ok"
    after
      Adapter.stop_session(session)
    end
  end

  test "stdio opens no TCP port, and teardown leaves no tmux server", %{workspace: ws} do
    {:ok, session} = Adapter.start_session(ws)
    os_pid = AppServerClient.os_pid(session.client)
    socket = session.tmux_socket

    # stdio transport: the Python child must not be listening on any TCP port.
    {lsof, _} = System.cmd("lsof", ["-nP", "-p", os_pid], stderr_to_stdout: true)
    refute lsof =~ "LISTEN"

    # The conversation's tmux session exists on this agent's private socket...
    assert {_, 0} =
             System.cmd(
               "tmux",
               ["-L", socket, "has-session", "-t", tmux_session(session.conversation_id)],
               stderr_to_stdout: true
             )

    Adapter.stop_session(session)

    # ...and the whole socket's server is gone after teardown (no orphan tmux).
    {_, code} = System.cmd("tmux", ["-L", socket, "has-session"], stderr_to_stdout: true)
    refute code == 0
  end

  test "interrupt stops a running turn", %{workspace: ws} do
    {:ok, session} = Adapter.start_session(ws)

    try do
      # No-wait turn so we can interrupt it mid-flight.
      assert {:ok, %{"accepted" => true}} =
               AppServerClient.request(
                 session.client,
                 "sendUserMessage",
                 %{
                   "conversationId" => session.conversation_id,
                   "text" => "Count slowly from 1 to 100, one number per line, pausing between each.",
                   "waitForCompletion" => false
                 },
                 30_000
               )

      Process.sleep(2_000)

      assert {:ok, %{"interrupted" => true}} =
               AppServerClient.request(
                 session.client,
                 "interruptConversation",
                 %{"conversationId" => session.conversation_id},
                 30_000
               )
    after
      Adapter.stop_session(session)
    end
  end

  test "crash recovery: resume re-adopts a dead session with full context", %{
    workspace: ws,
    issue: issue
  } do
    {:ok, session} = Adapter.start_session(ws)

    try do
      {:ok, _} = Adapter.run_turn(session, "Remember the number 7. Just acknowledge.", issue)

      # Simulate claude dying while the cc-appserver child stays alive.
      System.cmd(
        "tmux",
        ["-L", session.tmux_socket, "kill-session", "-t", tmux_session(session.conversation_id)],
        stderr_to_stdout: true
      )

      Process.sleep(1_000)

      assert {:ok, _} = Adapter.resume_session(session)

      {:ok, _} =
        Adapter.run_turn(
          session,
          "What number did I ask you to remember? Reply with only the number.",
          issue,
          on_message: collector()
        )

      completed = collected_events() |> Enum.find(&(&1.event == :turn_completed))
      assert completed.payload["reply"] =~ "7"
    after
      Adapter.stop_session(session)
    end
  end

  test "injected env (the LINEAR_API_KEY transport) reaches the agent's shell", %{workspace: ws} do
    # The adapter injects LINEAR_API_KEY=Bearer <token> into the child's env; it
    # must propagate child -> tmux server -> claude pane. Verify with a sentinel
    # injected the same way (waitForCompletion:true keeps this a one-shot).
    socket = "ccas_envtest_#{:rand.uniform(1_000_000)}"

    {:ok, client} =
      AppServerClient.start_link(
        python: System.find_executable("python3"),
        script: Path.expand("~/Documents/Coding/cc-appserver/cc_appserver.py"),
        tmux_socket: socket,
        workspace: ws,
        env: [{~c"CC_SENTINEL", ~c"symphony-env-ok"}]
      )

    try do
      {:ok, conv} =
        AppServerClient.request(client, "newConversation", %{"cwd" => ws, "model" => "sonnet"}, 90_000)

      {:ok, res} =
        AppServerClient.request(
          client,
          "sendUserMessage",
          %{
            "conversationId" => conv["conversationId"],
            "text" =>
              "Run this exact bash command and report only its output: " <>
                "echo CC_SENTINEL=$CC_SENTINEL",
            "waitForCompletion" => true
          },
          120_000
        )

      assert res["reply"] =~ "symphony-env-ok"
    after
      AppServerClient.stop(client)
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
    end
  end
end
