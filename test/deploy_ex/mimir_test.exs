defmodule DeployEx.MimirTest do
  use ExUnit.Case, async: true

  alias DeployEx.Mimir

  # PORT NOTE (opgg/main base): the MikaAK-line DeployEx.Mimir also carries
  # terraform_variables/1 (the Mimir terraform HCL block — HARD EXCLUDED from this
  # port per the sprint contract) and should_write_setup_playbook?/3 +
  # monitoring_setup_playbooks/0 (gates Mix.Tasks.Ansible.Build's .eex render of the
  # grafana_ui/loki_log_aggregator/prometheus_db setup playbooks — MEASURED absent on
  # opgg/main: no create_monitoring_setup_playbooks/1 caller, and
  # priv_renderer.ex's render_ansible/2 deletes every *.eex file under priv/ansible
  # before its explicit per-file re-renders, none of which name a monitoring setup
  # playbook, so a converted .eex there would either render inert or vanish on
  # export_priv — see mimir-core-port.md report). Neither has a home on this base
  # without touching excluded/out-of-scope renderer code, so only enabled?/1 ports.

  describe "enabled?/1" do
    test "returns true when :no_mimir is absent" do
      assert Mimir.enabled?([])
    end

    test "returns false when :no_mimir is true" do
      refute Mimir.enabled?(no_mimir: true)
    end

    test "returns true when :no_mimir is explicitly false" do
      assert Mimir.enabled?(no_mimir: false)
    end
  end
end
