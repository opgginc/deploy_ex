defmodule DeployEx.Mimir do
  @moduledoc """
  Whether Mimir is enabled for a build.

  PORT NOTE (opgg/main base): the MikaAK-line source module also carries
  `terraform_variables/1` (the Mimir terraform block) and the ansible.build
  `.eex` setup-playbook render gate (`should_write_setup_playbook?/3`,
  `monitoring_setup_playbooks/0`). Neither ports here: the terraform block is
  hard-excluded from this sprint, and the render gate has no caller on
  opgg/main's `Mix.Tasks.Ansible.Build` (no `create_monitoring_setup_playbooks/1`)
  or `DeployEx.PrivRenderer` (excluded) — see mimir-core-port.md report.
  """

  @doc "Whether mimir is enabled for this build (default ON, disabled via --no-mimir)."
  def enabled?(opts), do: not Keyword.get(opts, :no_mimir, false)
end
