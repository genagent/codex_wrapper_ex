defmodule Mix.Tasks.Codex.ContractTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Codex.Contract

  test "config checks reject a sentinel instead of accepting --help" do
    {binary, calls} = fake_cli()

    assert Contract.check(binary, [
             {"exec", ["exec", "--model", "fake", "-c", "approval_policy=\"never\""]}
           ]) == []

    probes =
      calls
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.ends_with?(&1, "--help"))

    assert [probe] = probes
    assert probe =~ "__codex_wrapper_contract_probe__"
    refute probe =~ "--help"
  end

  test "a CLI that accepts the invalid enum is not considered compatible" do
    {binary, _calls} = fake_cli("exit 0")

    assert [finding] =
             Contract.check(binary, [{"exec", ["exec", "-c", "approval_policy=\"never\""]}])

    assert finding =~ "did not reject the enum sentinel"
  end

  test "free-form config is refused before executing a probe" do
    {binary, calls} = fake_cli()
    assert [finding] = Contract.check(binary, [{"exec", ["exec", "-c", "model=\"fake\""]}])
    assert finding =~ "refusing unsafe config probe"
    assert [_help] = calls |> File.read!() |> String.split("\n", trim: true)
  end

  test "removed flags are reported" do
    {binary, _calls} = fake_cli()
    assert [finding] = Contract.check(binary, [{"exec", ["exec", "--removed-flag"]}])
    assert finding =~ "--removed-flag"
  end

  test "fork satisfies required CLI parsing before checking config" do
    {binary, calls} = fake_cli()

    assert Contract.check(binary, [
             {"exec fork", ["exec", "fork", "id", "-c", "sandbox_mode=\"read-only\""]}
           ]) == []

    assert File.read!(calls) =~ "exec fork contract-probe-session --strict-config"
  end

  defp fake_cli(probe_reply \\ "echo 'unknown variant __codex_wrapper_contract_probe__'; exit 1") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "codex-contract-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    binary = Path.join(dir, "codex")
    calls = Path.join(dir, "calls")

    File.write!(binary, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{calls}'
    case "$*" in
      *--help) printf 'Options:\\n  --model <MODEL>\\n  --strict-config\\n'; exit 0 ;;
    esac
    #{probe_reply}
    """)

    File.chmod!(binary, 0o755)
    {binary, calls}
  end
end
