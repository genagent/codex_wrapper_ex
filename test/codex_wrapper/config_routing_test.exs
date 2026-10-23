defmodule CodexWrapper.ConfigRoutingTest do
  use ExUnit.Case, async: false
  alias CodexWrapper.Commands.{Apply, Auth, Completion, Features, Mcp, McpServer, Version}
  alias CodexWrapper.{Config, Exec, ExecFork, ExecResume, Review, Runner}

  defmodule Capture do
    @behaviour Runner
    def validate_options(options) do
      Config.validate_runner_options!(options)
      :ok
    end

    def run(binary, args, options, timeout) do
      options =
        Map.new(options, fn
          {:env, entries} -> {:env, Enum.map(entries, &Tuple.to_list/1)}
          entry -> entry
        end)

      result = %{binary: binary, args: args, options: options, timeout: timeout}
      {:ok, {Jason.encode!(result), 0}}
    end
  end

  # Emulate Forcola's finite default without opening a native process.
  defmodule ForcolaStyle do
    @behaviour Runner
    def effective_timeout(nil), do: 300_000
    def effective_timeout(timeout), do: timeout

    def run(binary, args, options, timeout),
      do: Capture.run(binary, args, options, effective_timeout(timeout))
  end

  defmodule StreamCapture do
    @behaviour Runner
    def run(_, _, _, _), do: raise("one-shot callback invoked by stream")
    def stream_lines(_, _, _, _), do: [~s({"type":"turn.completed","usage":{}})]
  end

  defmodule Poison do
    def run(_, _, _, _), do: raise("application runner leaked into isolated invocation")
  end

  setup do
    prior =
      for key <- [:runner, :runner_options, :forcola_default_timeout_ms],
          do: {key, Application.fetch_env(:codex_wrapper, key)}

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, original} -> Application.put_env(:codex_wrapper, key, original)
          :error -> Application.delete_env(:codex_wrapper, key)
        end
      end
    end)

    :ok
  end

  test "concurrent same-provider configurations remain isolated with poisoned defaults" do
    before_os = System.get_env()

    configs =
      for suffix <- ["a", "b"] do
        Config.new(
          binary: "/native/#{suffix}/codex",
          working_dir: "/work/#{suffix}",
          env: [
            {"OPENAI_BASE_URL", "http://#{suffix}.invalid"},
            {"OPENAI_API_KEY", "fake-key-#{suffix}"},
            {"CODEX_HOME", "/config/#{suffix}"},
            {"MCP_CONFIG_ROOT", "/mcp/#{suffix}"}
          ],
          runner: Capture,
          runner_options: [
            env_mode: :replace,
            shim_path: "/shim/#{suffix}",
            max_output_bytes: 1_024,
            idle_timeout_ms: 90
          ],
          timeout: 200
        )
      end

    Application.put_env(:codex_wrapper, :runner, Poison)
    Application.put_env(:codex_wrapper, :runner_options, env_mode: :inherit, shim_path: "/poison")
    Application.put_env(:codex_wrapper, :forcola_default_timeout_ms, 1)
    before_app = Application.get_all_env(:codex_wrapper)

    tasks =
      for {config, suffix} <- Enum.zip(configs, ["a", "b"]) do
        Task.async(fn ->
          command =
            Exec.new("p")
            |> Exec.model("model-#{suffix}")
            |> Exec.config(~s(model_providers.same.base_url="http://#{suffix}.invalid"))
            |> Exec.config(~s(mcp_servers.local.command="/mcp/#{suffix}/server"))

          {:ok, result} = Exec.execute(command, config)
          {suffix, Jason.decode!(result.stdout)}
        end)
      end

    for task <- tasks do
      {suffix, capture} = Task.await(task)
      assert capture["binary"] == "/native/#{suffix}/codex"
      assert capture["timeout"] == 200
      assert capture["options"]["cd"] == "/work/#{suffix}"
      assert capture["options"]["shim_path"] == "/shim/#{suffix}"
      assert capture["options"]["env_mode"] == "replace"
      assert ["OPENAI_API_KEY", "fake-key-#{suffix}"] in capture["options"]["env"]
      assert ["CODEX_HOME", "/config/#{suffix}"] in capture["options"]["env"]
      assert ["MCP_CONFIG_ROOT", "/mcp/#{suffix}"] in capture["options"]["env"]
      assert "model-#{suffix}" in capture["args"]
      assert ~s(mcp_servers.local.command="/mcp/#{suffix}/server") in capture["args"]
    end

    assert Application.get_all_env(:codex_wrapper) == before_app
    assert System.get_env() == before_os
  end

  test "defaults snapshot only absent fields and explicit empty options override" do
    Application.put_env(:codex_wrapper, :runner, Capture)
    Application.put_env(:codex_wrapper, :runner_options, env_mode: :replace)
    default = Config.new(binary: "native")
    empty = Config.new(binary: "native", runner_options: [])
    Application.put_env(:codex_wrapper, :runner, Poison)
    Application.put_env(:codex_wrapper, :runner_options, not_an_option: :poison)
    assert Runner.impl(default) == Capture
    assert Config.runner_options(default) == [env_mode: :replace]
    assert Config.runner_options(empty) == []
    assert {:ok, _} = CodexWrapper.Runner.run(default, ["version"])
    assert {:ok, _} = CodexWrapper.Runner.run(empty, ["version"])
    # Explicit selection must not even consult an invalid application runner.
    Application.put_env(:codex_wrapper, :runner, {:invalid, :default})
    assert Config.new(runner: Capture, runner_options: []).runner == Capture
  end

  test "Forcola's legacy timeout default is captured rather than reread mid-run" do
    Application.put_env(:codex_wrapper, :forcola_default_timeout_ms, 125)
    config = Config.new(binary: "native", runner: Runner.Forcola, runner_options: [])
    Application.put_env(:codex_wrapper, :forcola_default_timeout_ms, 1)
    assert Runner.timeout(config) == 125
    assert Runner.timeout(%{config | timeout: 60}) == 60
    assert Runner.timeout(%{config | runner_options: [timeout_ms: 70]}) == 70
  end

  test "formerly System.cmd commands preserve Forcola-style default and explicit timeout routing" do
    for {timeout, expected} <- [{nil, 300_000}, {900_000, 900_000}] do
      config =
        Config.new(binary: "fake", runner: ForcolaStyle, runner_options: [], timeout: timeout)

      calls = [
        fn -> Apply.execute(config, "task") end,
        fn -> Auth.login(config, device_auth: true) end,
        fn -> Auth.logout(config) end,
        fn -> Auth.status(config) end,
        fn -> Completion.generate(config) end,
        fn -> Features.list(config) end,
        fn -> Mcp.list(config) end,
        fn -> McpServer.start(config) end
      ]

      for call <- calls do
        assert {:ok, output} = call.()
        assert Jason.decode!(output)["timeout"] == expected
      end

      assert {:ok, %{raw: output}} = Version.execute(config)
      assert Jason.decode!(output)["timeout"] == expected
    end
  end

  test "explicit runners without streaming fail before Port fallback or spawning" do
    for runner <- [Capture, __MODULE__.MissingRunner] do
      config = Config.new(binary: "never", runner: runner, runner_options: [])

      # Check the runner boundary without enumerating a possible Port fallback.
      assert_raise ArgumentError, ~r/explicit runner .* does not implement stream_lines/, fn ->
        Runner.stream_lines(config, "never", [], [], nil)
      end

      for command <- [Exec.new("p"), ExecResume.new(), ExecFork.new("source"), Review.new()] do
        mod = command.__struct__

        assert_raise ArgumentError, ~r/explicit runner .* does not implement stream_lines/, fn ->
          command |> mod.stream(config) |> Enum.to_list()
        end
      end
    end

    direct = %Config{binary: "never", runner: Capture, runner_options: []}

    assert_raise ArgumentError, ~r/explicit runner/, fn ->
      Runner.stream_lines(direct, "never", [], [], nil)
    end
  end

  test "implicit snapshotted and direct default selection retain lazy Port fallback" do
    Application.put_env(:codex_wrapper, :runner, Capture)
    Application.put_env(:codex_wrapper, :runner_options, [])
    implicit = Config.new(binary: "never")
    assert implicit.runner_explicit == false

    for config <- [implicit, %Config{binary: "never", runner_options: []}] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          stream = Runner.stream_lines(config, "never", [], [], nil)
          assert Enumerable.impl_for(stream)
        end)

      assert log =~ "falling back to CodexWrapper.Runner.Port"
    end
  end

  test "explicit runners with streaming callbacks remain supported" do
    config = Config.new(binary: "fake", runner: StreamCapture, runner_options: [])

    for command <- [Exec.new("p"), ExecResume.new(), ExecFork.new("source"), Review.new()] do
      mod = command.__struct__
      assert [_event] = command |> mod.stream(config) |> Enum.to_list()
    end
  end

  test "all one-shot commands and convenience paths use immutable runner options" do
    config = Config.new(binary: "native", runner: Capture, runner_options: [env_mode: :replace])

    for command <- [Exec.new("p"), ExecResume.new(), ExecFork.new("source"), Review.new()] do
      mod = command.__struct__
      assert {:ok, result} = mod.execute(command, config)
      assert Jason.decode!(result.stdout)["options"]["env_mode"] == "replace"
    end

    calls = [
      fn -> Apply.execute(config, "task") end,
      fn -> Auth.status(config) end,
      fn -> Auth.login(config) end,
      fn -> Auth.logout(config) end,
      fn -> Completion.generate(config) end,
      fn -> Features.list(config) end,
      fn -> Features.enable(config, "flag") end,
      fn -> Features.disable(config, "flag") end,
      fn -> Mcp.list(config) end,
      fn -> Mcp.get(config, "server") end,
      fn -> Mcp.add(config, "server", :stdio, command: "server") end,
      fn -> Mcp.add(config, "server", :http, url: "http://local.invalid") end,
      fn -> Mcp.remove(config, "server") end,
      fn -> Mcp.login(config, "server") end,
      fn -> Mcp.logout(config, "server") end,
      fn -> McpServer.start(config) end
    ]

    for call <- calls do
      assert {:ok, output} = call.()
      assert Jason.decode!(output)["options"]["env_mode"] == "replace"
    end

    assert {:ok, %{raw: output}} = Version.execute(config)
    assert Jason.decode!(output)["options"]["env_mode"] == "replace"

    opts = [
      binary: "native",
      runner: Capture,
      runner_options: [env_mode: :replace],
      model: "custom"
    ]

    assert {:ok, result} = CodexWrapper.exec("p", opts)
    assert "custom" in Jason.decode!(result.stdout)["args"]
    assert {:ok, output} = CodexWrapper.raw(["version"], opts)
    assert Jason.decode!(output)["options"]["env_mode"] == "replace"
    assert {:ok, %{raw: _}} = CodexWrapper.version(opts)
    assert {:ok, _} = CodexWrapper.completion(:bash, opts)
    assert {:ok, _} = CodexWrapper.review(opts)
  end

  test "invalid and unsupported new requirements fail before subprocess invocation" do
    for options <- [
          nil,
          %{},
          [:invalid],
          [unknown: true],
          [max_output_bytes: :infinity],
          [idle_timeout_ms: 0],
          [timeout_ms: -1],
          [shim_path: "relative"],
          [interrupt_signal: :term, interrupt_grace_ms: 5],
          [interrupt_signal: :int],
          [env_mode: :other],
          [max_output_bytes: 1, max_output_bytes: 2]
        ] do
      assert_raise ArgumentError, fn -> Config.new(runner_options: options) end
    end

    config =
      Config.new(binary: "never", runner: Runner.Port, runner_options: [env_mode: :replace])

    assert {:error, {:runner_options_unsupported, Runner.Port}} = Runner.run(config, [])

    assert_raise ArgumentError, ~r/one-shot/, fn ->
      Exec.stream(Exec.new("p"), config) |> Enum.to_list()
    end
  end
end
