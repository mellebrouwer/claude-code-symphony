defmodule SymphonyElixir.ClaudeCode.AppServerClientTest do
  @moduledoc """
  Fast protocol/framing checks for the cc-appserver stdio client. These spawn the
  Python server but never open a conversation, so they need `python3` + the
  cc-appserver script but NOT a real `claude` — they run in the default suite.
  Compiled only when those are present, so the suite stays green elsewhere.
  """
  use ExUnit.Case, async: false

  alias SymphonyElixir.ClaudeCode.AppServerClient

  @script Path.expand("~/Documents/Coding/cc-appserver/cc_appserver.py")
  @python System.find_executable("python3")

  if @python && File.regular?(@script) do
    setup do
      workspace = Path.join(System.tmp_dir!(), "ccas_client_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(workspace)
      socket = "ccas_clienttest_#{:rand.uniform(1_000_000)}"

      {:ok, client} =
        AppServerClient.start_link(
          python: @python,
          script: @script,
          tmux_socket: socket,
          workspace: workspace,
          env: []
        )

      on_exit(fn ->
        if Process.alive?(client), do: AppServerClient.stop(client)
        System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
        File.rm_rf(workspace)
      end)

      %{client: client}
    end

    test "ping round-trips over the stdio port", %{client: client} do
      assert {:ok, %{"pong" => true}} = AppServerClient.request(client, "ping", %{}, 10_000)
    end

    test "rpc.discover returns the OpenRPC contract", %{client: client} do
      assert {:ok, result} = AppServerClient.request(client, "rpc.discover", %{}, 10_000)
      names = (result["methods"] || []) |> Enum.map(& &1["name"])
      assert "newConversation" in names
      assert "sendUserMessage" in names
    end

    test "concurrent requests each correlate to their own response by id", %{client: client} do
      # Issue several in flight from separate processes; every one must get its
      # own pong back (proves the pending-by-id map, not a single in/out pair).
      tasks = for _ <- 1..6, do: Task.async(fn -> AppServerClient.request(client, "ping", %{}, 10_000) end)
      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &match?({:ok, %{"pong" => true}}, &1))
    end

    test "an unknown method comes back as an rpc error, not a crash", %{client: client} do
      assert {:error, %{"code" => _}} = AppServerClient.request(client, "definitely.not.a.method", %{}, 10_000)
      # The client survives and still serves requests.
      assert {:ok, %{"pong" => true}} = AppServerClient.request(client, "ping", %{}, 10_000)
    end

    test "request after the child stops reports the child is down", %{client: client} do
      AppServerClient.stop(client)
      assert {:error, :appserver_down} = AppServerClient.request(client, "ping", %{}, 5_000)
    end
  end
end
