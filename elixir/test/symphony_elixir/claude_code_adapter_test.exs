defmodule SymphonyElixir.ClaudeCode.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaudeCode.Adapter

  setup do
    workflow_path =
      Path.join([System.tmp_dir!(), "symphony_cc_test_workflow_#{:rand.uniform(100_000)}.md"])

    workspace_root = Path.join(System.tmp_dir!(), "symphony_cc_test_workspaces")
    workspace = Path.join(workspace_root, "test-issue-1")

    File.mkdir_p!(workspace)

    File.write!(workflow_path, """
    ---
    tracker:
      kind: memory
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
    claude_code:
      command: claude
      turn_timeout_ms: 120000
      stall_timeout_ms: 60000
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

    canonical_workspace =
      case SymphonyElixir.PathSafety.canonicalize(Path.expand(workspace)) do
        {:ok, path} -> path
        _ -> workspace
      end

    %{workspace: canonical_workspace}
  end

  describe "start_session/2" do
    test "creates a session with an agent for session_id tracking", %{workspace: workspace} do
      assert {:ok, session} = Adapter.start_session(workspace)
      assert is_pid(session.session_id_agent)
      assert session.workspace == workspace
      assert is_nil(session.worker_host)
      assert Agent.get(session.session_id_agent, & &1) == nil

      Adapter.stop_session(session)
    end
  end

  describe "run_turn/4" do
    @tag timeout: 120_000
    test "spawns claude and parses stream-json output", %{workspace: workspace} do
      {:ok, session} = Adapter.start_session(workspace)

      events = :ets.new(:test_events, [:bag, :public])

      on_message = fn message ->
        :ets.insert(events, {message.event, message})
        :ok
      end

      issue = %SymphonyElixir.Linear.Issue{
        id: "test-1",
        identifier: "TEST-1",
        title: "Test issue",
        state: "Todo"
      }

      result = Adapter.run_turn(session, "say exactly: hello symphony test", issue, on_message: on_message)

      recorded_events = :ets.tab2list(events) |> Enum.map(fn {event, _msg} -> event end)

      assert :session_started in recorded_events

      case result do
        {:ok, turn_result} ->
          assert turn_result.result == :turn_completed
          assert is_binary(turn_result.session_id)
          assert :turn_completed in recorded_events

        {:error, reason} ->
          flunk("run_turn failed: #{inspect(reason)}")
      end

      final_session_id = Agent.get(session.session_id_agent, & &1)
      assert is_binary(final_session_id)

      :ets.delete(events)
      Adapter.stop_session(session)
    end
  end

  describe "stop_session/1" do
    test "stops the session agent", %{workspace: workspace} do
      {:ok, session} = Adapter.start_session(workspace)
      assert Process.alive?(session.session_id_agent)

      Adapter.stop_session(session)
      refute Process.alive?(session.session_id_agent)
    end
  end
end
