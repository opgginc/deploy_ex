defmodule DeployEx.MimirRoleTest do
  use ExUnit.Case, async: true

  # priv/ansible/roles/mimir_db and its downstream j2/yaml templates are Ansible/Jinja
  # content, not Elixir-rendered — covered here via structural/content assertions plus
  # one real Jinja2 render (see "alloy_config.alloy.j2 — real render").
  #
  # PORT NOTE (opgg/main base, MEASURED): the MikaAK-line mimir_db role shares its
  # ruler alert rules with prometheus_db via a `{{ role_path }}/../prometheus_db/...`
  # reference. opgg/main's prometheus_db role has no `templates/prometheus-rules.yaml.j2`
  # at all (git cat-file -e opgg/main:priv/ansible/roles/prometheus_db/templates/prometheus-rules.yaml.j2
  # returns "does not exist"), and prometheus_db is out of this port's collision-measured
  # scope. mimir_db therefore ships its OWN copy of the rules content instead of
  # referencing prometheus_db's (nonexistent, on this base) copy — duplication over a
  # broken cross-role reference. See mimir-core-port.md report for the full measurement.
  #
  # Baseline fixtures under test/support/fixtures/mimir/{prometheus_db_role,
  # baseline_alloy_config.alloy.j2} are captures of opgg/main @ ef98382 (this port's
  # base commit) — NOT MikaAK-line captures — because prometheus_db's actual content
  # differs substantially between the two lines and the invariant under test is
  # "this port left prometheus_db untouched on opgg/main", which only a same-base
  # capture can prove.

  @app_name_pre_fix ~s[replacement  = "{{ app_name }}"]
  @app_name_post_fix ~s[replacement  = "{{ app_name | default('') }}"]

  @priv_roles_dir Path.expand("../../priv/ansible/roles", __DIR__)
  @mimir_role_dir Path.join(@priv_roles_dir, "mimir_db")
  @prometheus_role_dir Path.join(@priv_roles_dir, "prometheus_db")
  @fixtures_dir Path.expand("../support/fixtures/mimir", __DIR__)

  # SECTION: prometheus_db role untouched (out of this port's scope)

  describe "prometheus_db role files — untouched by this port" do
    for relative_path <- [
          "tasks/main.yaml",
          "templates/prometheus.service.j2",
          "templates/prometheus.yaml.j2"
        ] do
      test "#{relative_path} is byte-identical to the opgg/main baseline" do
        relative_path = unquote(relative_path)

        baseline = File.read!(Path.join([@fixtures_dir, "prometheus_db_role", relative_path]))
        current = File.read!(Path.join(@prometheus_role_dir, relative_path))

        assert current === baseline
      end
    end

    test "still has no templates/prometheus-rules.yaml.j2 (this port did not add one there)" do
      refute File.exists?(Path.join(@prometheus_role_dir, "templates/prometheus-rules.yaml.j2"))
    end
  end

  # SECTION: mimir_db role — own copy of alert rules (no cross-role reference)

  describe "mimir_db role — alert rules (own copy, adapted from the port)" do
    test "tasks/main.yaml references its own local rules template, not a cross-role role_path" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "src: prometheus-rules.yaml.j2"
      refute content =~ ~s[src: "{{ role_path }}]
    end

    test "keeps its own copy of prometheus-rules.yaml.j2" do
      assert File.exists?(Path.join(@mimir_role_dir, "templates/prometheus-rules.yaml.j2"))
    end

    test "the own-copy rules content carries the shared alert set (node/nodes/apps)" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/prometheus-rules.yaml.j2"))

      assert content =~ "SystemdUnitFailed"
      assert content =~ "TargetDown"
      assert content =~ "NoNodesDiscovered"
      assert content =~ "NoAppsDiscovered"
    end
  end

  # SECTION: mimir_db role — structure

  describe "mimir_db role — task structure" do
    test "downloads the pinned Mimir binary, installs config + systemd unit, restarts on change" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "mimir_version"
      assert content =~ "mimir-config.yaml.j2"
      assert content =~ "mimir_systemd.service.j2"
      assert content =~ "name: mimir"
    end

    test "asserts /data is a mounted filesystem before writing Mimir data there (guards against filling the root volume)" do
      content = File.read!(Path.join(@mimir_role_dir, "tasks/main.yaml"))

      assert content =~ "assert:"
      assert content =~ ~s[selectattr('mount', 'equalto', '/data')]
    end
  end

  describe "mimir_db role — defaults" do
    test "pins a Mimir version and the shared HTTP port" do
      content = File.read!(Path.join(@mimir_role_dir, "defaults/main.yaml"))

      assert content =~ "mimir_version:"
      assert content =~ "mimir_http_port: 8080"
    end
  end

  describe "mimir_db role — config template" do
    test "runs monolithic mode with filesystem blocks storage and the ruler enabled" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ "target: all"
      assert content =~ "backend: filesystem"
      assert content =~ "ruler:"
      assert content =~ "enable_api: true"
      assert content =~ "http_listen_port: {{ mimir_http_port }}"
    end

    test "pins prometheus_http_prefix so the Grafana datasource query path can't drift with Mimir versions" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ "api:"
      assert content =~ "prometheus_http_prefix: /prometheus"
    end

    test "ruler_storage uses the local backend so the ruler actually loads rule groups from disk" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ ~r/ruler_storage:\s*\n\s*backend: local/
      assert content =~ ~r/local:\s*\n\s*directory: \/data\/mimir\/rules/
      refute content =~ ~r/ruler_storage:\s*\n\s*filesystem:/
    end

    test "every data path lives under /data/mimir — no fallback to the root volume" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir-config.yaml.j2"))

      assert content =~ "dir: /data/mimir/common"
      assert content =~ "dir: /data/mimir/blocks"
      assert content =~ "sync_dir: /data/mimir/tsdb-sync"
      assert content =~ "dir: /data/mimir/tsdb"
      assert content =~ "data_dir: /data/mimir/compactor"
      assert content =~ "rule_path: /data/mimir/ruler"
      assert content =~ "directory: /data/mimir/rules"
      assert content =~ "data_dir: /data/mimir/alertmanager"
      assert content =~ "dir: /data/mimir/alertmanager-config"
    end
  end

  describe "mimir_db role — systemd unit" do
    test "requires /data to be mounted before starting (second gate, alongside the play-time assert)" do
      content = File.read!(Path.join(@mimir_role_dir, "templates/mimir_systemd.service.j2"))

      assert content =~ "RequiresMountsFor=/data"
    end
  end

  # SECTION: grafana_alloy tasks — opgg's two collision-surface fixes preserved

  describe "grafana_alloy/tasks/main.yaml — opgg's ansible-core 2.14 + Ubuntu 24.04 fixes preserved" do
    @alloy_tasks_path Path.join(@priv_roles_dir, "grafana_alloy/tasks/main.yaml")

    test "does not use the removed `args: warn: false` command parameter (ansible-core 2.14+ hard error)" do
      content = File.read!(@alloy_tasks_path)

      refute content =~ "warn: false"
    end

    test "installs unzip before extracting the Alloy .zip release (Ubuntu 24.04 has none by default)" do
      content = File.read!(@alloy_tasks_path)

      assert content =~ ~r/name:\s+Install unzip/
      assert content =~ "name: unzip"
    end

    test "notifies the restart alloy handler when config or unit changes" do
      content = File.read!(@alloy_tasks_path)

      assert content =~ "notify: restart alloy"
    end
  end

  describe "grafana_alloy/handlers/main.yaml" do
    test "declares a restart alloy handler with its own become" do
      content = File.read!(Path.join(@priv_roles_dir, "grafana_alloy/handlers/main.yaml"))

      assert content =~ "name: restart alloy"
      assert content =~ "become: true"
      assert content =~ "state: restarted"
    end
  end

  # SECTION: alloy_config.alloy.j2 — metrics pipeline (raw j2 — structural assertions)

  describe "alloy_config.alloy.j2 — metrics pipeline" do
    @alloy_path Path.join(@priv_roles_dir, "grafana_alloy/templates/alloy_config.alloy.j2")
    @alloy_defaults_path Path.join(@priv_roles_dir, "grafana_alloy/defaults/main.yaml")

    test "scrapes node_exporter and app metrics locally, remote_writes to Mimir, no ec2_sd" do
      content = File.read!(@alloy_path)

      assert content =~ "{% if grafana_mimir_url is defined %}"
      assert content =~ "localhost:9100"
      assert content =~ "{% if app_name is defined %}"
      assert content =~ "localhost:{{ alloy_app_metrics_port }}"
      assert content =~ ~s(prometheus.remote_write "mimir")
      assert content =~ "{{ grafana_mimir_url }}"
      refute content =~ "ec2_sd"
    end

    test "the app scrape port is the alloy_app_metrics_port variable, read bare with no default() filter" do
      content = File.read!(@alloy_path)

      assert content =~ ~s("__address__" = "localhost:{{ alloy_app_metrics_port }}",)
      refute content =~ "alloy_app_metrics_port | default"
      refute content =~ "alloy_app_metrics_port|default"
      refute content =~ "localhost:4050"
    end

    test "defaults/main.yaml declares alloy_app_metrics_port: 4050 (the single source of truth)" do
      content = File.read!(@alloy_defaults_path)

      assert content =~ "alloy_app_metrics_port: 4050"
    end

    test "the loki pipeline is untouched apart from the app_name default('') guard (see next test)" do
      baseline = File.read!(Path.join(@fixtures_dir, "baseline_alloy_config.alloy.j2"))
      expected_loki_pipeline = String.replace(baseline, @app_name_pre_fix, @app_name_post_fix)
      content = File.read!(@alloy_path)

      assert String.starts_with?(content, String.trim_trailing(expected_loki_pipeline))
    end

    test "the journal relabel rule's app_name reference defaults instead of crashing monitoring-node plays" do
      baseline = File.read!(Path.join(@fixtures_dir, "baseline_alloy_config.alloy.j2"))
      content = File.read!(@alloy_path)

      assert baseline =~ @app_name_pre_fix
      refute content =~ @app_name_pre_fix
      assert content =~ @app_name_post_fix
    end

    test "labels scraped series job=nodes/job=apps so the shared NoNodesDiscovered/NoAppsDiscovered/TargetDown rules stay live under push" do
      content = File.read!(@alloy_path)

      assert content =~ ~r/prometheus\.scrape "node_exporter" \{\s*\n\s*job_name\s*=\s*"nodes"/
      assert content =~ ~r/prometheus\.scrape "app" \{\s*\n\s*job_name\s*=\s*"apps"/
    end

    test "attaches instance + instance_id labels to pushed series" do
      content = File.read!(@alloy_path)

      assert content =~ ~s["instance"    = "{{ inventory_hostname }}"]
      assert content =~ ~s["instance_id" = "{{ instance_id | default('unknown') }}"]
    end
  end

  # SECTION: alloy_config.alloy.j2 — real render (Done criterion 4: render for real, not a
  # fixture-string assertion). Shells out to the jinja2 install ansible-core itself depends
  # on, so the render exercises the ACTUAL Jinja2 engine that will run this template in
  # production, not a hand-rolled Elixir template evaluator.

  describe "alloy_config.alloy.j2 — real render" do
    @alloy_path Path.join(@priv_roles_dir, "grafana_alloy/templates/alloy_config.alloy.j2")

    @base_context %{
      "grafana_loki_url" => "http://loki.internal:3100",
      "grafana_mimir_url" => "http://mimir.internal:8080",
      "app_name" => "my_app",
      "inventory_hostname" => "app-001",
      "instance_id" => "i-0abc123"
    }

    test "rendering with the real default port (4050) produces both scrape targets" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 4050))

      assert rendered =~ "\"__address__\" = \"localhost:9100\","
      assert rendered =~ "\"__address__\" = \"localhost:4050\","
    end

    test "overriding alloy_app_metrics_port changes the app scrape target and purges the literal 4050, while node_exporter's 9100 stays untouched" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 9999))

      assert rendered =~ "\"__address__\" = \"localhost:9999\","
      assert rendered =~ "\"__address__\" = \"localhost:9100\","
      refute rendered =~ "4050"
    end

    test "control: the render instrument itself can fail (proves the assertions above are not vacuous)" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 9999))

      refute rendered =~ "\"__address__\" = \"localhost:1234\","
    end

    test "omitting grafana_mimir_url renders no prometheus.scrape/remote_write at all (logs-only fallback preserved)" do
      loki_only_context = Map.take(@base_context, ["grafana_loki_url"])

      rendered = render_jinja!(@alloy_path, loki_only_context)

      refute rendered =~ "prometheus.scrape"
      refute rendered =~ "prometheus.remote_write"
      assert rendered =~ "loki.write \"default\""
    end
  end

  # SECTION: grafana-datasources.yaml.j2 — Mimir datasource (raw j2 — structural assertions)

  describe "grafana-datasources.yaml.j2 — Mimir datasource" do
    @datasource_path Path.join(@priv_roles_dir, "grafana_ui/templates/grafana-datasources.yaml.j2")

    test "adds a Mimir prometheus-type datasource under the grafana_mimir_url conditional" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_mimir_url is defined %}"
      assert content =~ "name: Mimir Metrics"
      assert content =~ "type: prometheus"
      assert content =~ "url: {{ grafana_mimir_url }}/prometheus"
    end

    test "existing Loki entry is untouched" do
      loki_entry = """
      apiVersion: 1

      datasources:
        - name: Loki Logs
          type: loki
          user: $USER
          url: {{ grafana_loki_url }}
      """

      content = File.read!(@datasource_path)

      assert String.starts_with?(content, String.trim_trailing(loki_entry))
    end

    test "wraps the Prometheus entry in {% if grafana_prometheus_url is defined %} so --no-prometheus + mimir renders instead of crashing" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_prometheus_url is defined %}"
      assert content =~ "name: Prometheus Metrics"

      prometheus_if = :binary.match(content, "{% if grafana_prometheus_url is defined %}") |> elem(0)
      mimir_if = :binary.match(content, "{% if grafana_mimir_url is defined %}") |> elem(0)
      endif_positions = for [{pos, _}] <- Regex.scan(~r/\{% endif %\}/, content, return: :index), do: pos

      prometheus_endif = Enum.find(endif_positions, &(&1 > prometheus_if))

      assert prometheus_if < prometheus_endif
      assert prometheus_endif < mimir_if
    end
  end

  # SECTION: setup/mimir_db.yaml — new opt-in monitoring node playbook

  describe "setup/mimir_db.yaml" do
    @setup_playbook_path Path.expand("../../priv/ansible/setup/mimir_db.yaml", __DIR__)

    test "targets the monitoring_mimir_db host group and includes the mimir_db + grafana_alloy roles" do
      content = File.read!(@setup_playbook_path)

      assert content =~ "hosts: monitoring_mimir_db"
      assert content =~ "- mimir_db"
      assert content =~ "- grafana_alloy"
    end

    test "does not reference the data_volume_grow role (does not exist on opgg/main — MEASURED absent)" do
      content = File.read!(@setup_playbook_path)

      refute content =~ "data_volume_grow"
    end
  end

  # SECTION: real-render helper — shells out to ansible-core's own bundled Jinja2, the
  # exact engine that will render this template in production. Raises loudly (never
  # skips) when no Jinja2-capable python is found — a missing interpreter is a test
  # environment defect, not a reason to silently pass.

  defp render_jinja!(template_path, context) do
    python = jinja_python!()
    script = jinja_render_script()
    context_json = Jason.encode!(context)

    {output, exit_status} = System.cmd(python, ["-c", script, template_path, context_json])

    if exit_status !== 0 do
      raise "jinja2 render of #{template_path} failed (exit #{exit_status}): #{output}"
    end

    output
  end

  defp jinja_python! do
    Enum.find(jinja_python_candidates(), &jinja_capable?/1) ||
      raise "no python interpreter with jinja2 installed was found among #{inspect(jinja_python_candidates())} — install ansible-core (brew install ansible) or jinja2 (pip install jinja2)"
  end

  defp jinja_python_candidates do
    [ansible_bundled_python(), System.find_executable("python3")]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ansible_bundled_python do
    with ansible_playbook when is_binary(ansible_playbook) <- System.find_executable("ansible-playbook"),
         {:ok, shebang_line} <- File.open(ansible_playbook, [:read], &IO.read(&1, :line)),
         "#!" <> python_path <- String.trim(shebang_line) do
      python_path
    else
      _ -> nil
    end
  end

  defp jinja_capable?(python) do
    case System.cmd(python, ["-c", "import jinja2"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp jinja_render_script do
    """
    import sys, json, jinja2
    template_path, context_json = sys.argv[1], sys.argv[2]
    context = json.loads(context_json)
    with open(template_path) as source_file:
      template = jinja2.Template(source_file.read())
    sys.stdout.write(template.render(**context))
    """
  end
end
