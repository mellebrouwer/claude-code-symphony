# `:live` tests drive a real `claude` binary through cc-appserver — slow and
# token-costing. Excluded by default; run them with `mix test --include live`.
ExUnit.start(exclude: [:live])
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
