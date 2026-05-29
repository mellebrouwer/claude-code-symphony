defmodule SymphonyElixir.ArchiveDoneIssuesTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(
      Application.get_env(:symphony_elixir, :workflow_file_path),
      tracker_kind: "memory",
      tracker_archive_done_after_hours: 24
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  describe "archive timer fires and archives stale Done issues" do
    test "archives issues in Done state older than threshold" do
      stale_time = DateTime.add(DateTime.utc_now(), -25, :hour)
      fresh_time = DateTime.add(DateTime.utc_now(), -1, :hour)

      stale_issue = %Issue{
        id: "stale-1",
        identifier: "MEL-100",
        title: "Old done issue",
        state: "Done",
        updated_at: stale_time
      }

      fresh_issue = %Issue{
        id: "fresh-1",
        identifier: "MEL-101",
        title: "Recently done issue",
        state: "Done",
        updated_at: fresh_time
      }

      in_progress_issue = %Issue{
        id: "active-1",
        identifier: "MEL-102",
        title: "Still working",
        state: "In Progress",
        updated_at: stale_time
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        stale_issue,
        fresh_issue,
        in_progress_issue
      ])

      orchestrator_name = Module.concat(__MODULE__, :ArchiveOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :archive_done_issues)
      assert_receive {:memory_tracker_archive, "stale-1"}, 2_000
      refute_receive {:memory_tracker_archive, "fresh-1"}, 200
      refute_receive {:memory_tracker_archive, "active-1"}, 200
    end

    test "does not archive when threshold is 0 (disabled)" do
      write_workflow_file!(
        Application.get_env(:symphony_elixir, :workflow_file_path),
        tracker_kind: "memory",
        tracker_archive_done_after_hours: 0
      )

      stale_issue = %Issue{
        id: "stale-disabled",
        identifier: "MEL-200",
        title: "Old but archiving disabled",
        state: "Done",
        updated_at: DateTime.add(DateTime.utc_now(), -48, :hour)
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [stale_issue])

      orchestrator_name = Module.concat(__MODULE__, :ArchiveDisabledOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :archive_done_issues)
      refute_receive {:memory_tracker_archive, _}, 500
    end

    test "handles issues with nil updated_at gracefully" do
      stale_issue = %Issue{
        id: "stale-with-date",
        identifier: "MEL-300",
        title: "Has date",
        state: "Done",
        updated_at: DateTime.add(DateTime.utc_now(), -48, :hour)
      }

      nil_date_issue = %Issue{
        id: "nil-date",
        identifier: "MEL-301",
        title: "No date",
        state: "Done",
        updated_at: nil
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [stale_issue, nil_date_issue])

      orchestrator_name = Module.concat(__MODULE__, :ArchiveNilDateOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :archive_done_issues)
      assert_receive {:memory_tracker_archive, "stale-with-date"}, 2_000
      refute_receive {:memory_tracker_archive, "nil-date"}, 200
    end

    test "archives multiple stale issues" do
      base_time = DateTime.add(DateTime.utc_now(), -72, :hour)

      issues =
        for i <- 1..5 do
          %Issue{
            id: "batch-#{i}",
            identifier: "MEL-#{400 + i}",
            title: "Batch issue #{i}",
            state: "Done",
            updated_at: DateTime.add(base_time, -i, :hour)
          }
        end

      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      orchestrator_name = Module.concat(__MODULE__, :ArchiveBatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :archive_done_issues)

      archived_ids =
        for _ <- 1..5 do
          assert_receive {:memory_tracker_archive, id}, 2_000
          id
        end

      assert Enum.sort(archived_ids) == Enum.map(1..5, &"batch-#{&1}")
    end
  end

  describe "archive timer scheduling" do
    test "reschedules after handling archive message" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :ArchiveRescheduleOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
      end)

      send(pid, :archive_done_issues)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end
end
