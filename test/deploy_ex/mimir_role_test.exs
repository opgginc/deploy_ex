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

    # opgg's original 16-line fix guarded the unzip install with `when: not
    # alloy.stat.exists` (skip the apt call on repeat runs once Alloy is already
    # present). #26 (975c5d3, reconciled alongside opgg's fix here) made `alloy`
    # itself version-aware — same variable name, now registered from a
    # version-scoped stat — so the guard composes unchanged: still "skip the
    # unzip install once this exact version is already installed".
    test "installs unzip, guarded by opgg's `when: not alloy.stat.exists` (skips redundant apt calls on repeat runs)" do
      unzip_task = Enum.find(YamlElixir.read_from_file!(@alloy_tasks_path) |> flatten_tasks_for_test(), fn task ->
        get_in(task, ["apt", "name"]) === "unzip"
      end)

      refute is_nil(unzip_task), "expected a task installing the unzip apt package"
      assert unzip_task["when"] === "not alloy.stat.exists"
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

      assert content =~ "{% if grafana_mimir_url_configured %}"
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

    # F59: deploy_ex is a general tool and must not learn one consumer's release
    # topology. opgg's incident fix (O8, 2026-08-31) hardcodes
    # `app_name in ['pipeline', 'polling']` in their own hand-edited, generated
    # tree — deploy_ex ships the SCOPE as a role default instead, empty by default
    # (unrestricted, preserving every existing consumer's current behavior), so a
    # consumer expresses their topology in configuration that survives
    # `mix ansible.build` rather than in a hand-edit that gets clobbered by it.
    test "defaults/main.yaml declares alloy_app_metrics_scrape_app_names: [] (unrestricted by default, no consumer release names hardcoded)" do
      content = File.read!(@alloy_defaults_path)

      assert content =~ "alloy_app_metrics_scrape_app_names: []"
    end

    test "the template reads the scope bare, with no default() filter (deploy_ex names no consumer release class)" do
      content = File.read!(@alloy_path)

      assert content =~ "alloy_app_metrics_scrape_app_names"
      refute content =~ "alloy_app_metrics_scrape_app_names | default"
      refute content =~ "alloy_app_metrics_scrape_app_names|default"
      refute content =~ ~s(['pipeline')
      refute content =~ ~s(["pipeline")
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
      "grafana_mimir_url_configured" => true,
      "app_name" => "my_app",
      "inventory_hostname" => "app-001",
      "instance_id" => "i-0abc123"
    }

    test "rendering with the real default port (4050) produces both scrape targets" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 4050))

      assert rendered =~ "\"__address__\" = \"localhost:9100\","
      assert rendered =~ "\"__address__\" = \"localhost:4050\","
      assert_alloy_valid!(rendered)
    end

    test "overriding alloy_app_metrics_port changes the app scrape target and purges the literal 4050, while node_exporter's 9100 stays untouched" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 9999))

      assert rendered =~ "\"__address__\" = \"localhost:9999\","
      assert rendered =~ "\"__address__\" = \"localhost:9100\","
      refute rendered =~ "4050"
      assert_alloy_valid!(rendered)
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
      assert_alloy_valid!(rendered)
    end

    # opgg's own review (PR #120) found that a substring assertion CANNOT catch this
    # class of defect: a reviewer commented a prometheus.scrape block out with `#`,
    # which is not a comment character in Alloy's River config language (`//` is).
    # Every substring assertion still passed because the literal text was still
    # present *inside* the "comment" — the file was no longer valid Alloy and nothing
    # noticed. `alloy validate` is the arm that discriminates; this test proves it by
    # reproducing the exact defect and showing both halves of the claim in one place:
    # the substring check stays green, and validate does not.
    test "alloy validate catches a `#`-commented block that a substring assertion cannot (opgg PR #120 defect class)" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "alloy_app_metrics_port", 4050))
      mutated = String.replace(rendered, ~s(prometheus.scrape "app" {), ~s(# prometheus.scrape "app" {))

      assert mutated =~ "prometheus.scrape \"app\""
      refute alloy_validate_exit_status(mutated) === 0
    end
  end

  # SECTION: alloy_config.alloy.j2 — app-metrics scrape scoping (F59, real render)
  #
  # Newly approved onto this port after opgg's O8 production OOM (2026-08-31):
  # PrometheusTelemetry's _dist ETS tables only drain when something GETs
  # /metrics. Release classes with no HTTP endpoint of their own (opgg's
  # "pipeline"/"polling") never get scraped by anything else, so those tables grow
  # unbounded — Alloy's app scrape is what drains them. Release classes that DO run
  # their own bearer-gated listener on a different port ("server"/"service", per
  # opgg's own comment) must NOT gain a second, unauthenticated scrape target.
  #
  # deploy_ex must not learn opgg's release names — alloy_app_metrics_scrape_app_names
  # is a role default (empty list = unrestricted, matching every existing consumer's
  # current behavior unchanged) that a consumer sets to their own list. Same pattern
  # as alloy_app_metrics_port: role default, read bare, no `| default(...)` filter.

  describe "alloy_config.alloy.j2 — app-metrics scrape scoping (F59)" do
    @alloy_path Path.join(@priv_roles_dir, "grafana_alloy/templates/alloy_config.alloy.j2")

    @base_context %{
      "grafana_loki_url" => "http://loki.internal:3100",
      "grafana_mimir_url" => "http://mimir.internal:8080",
      "grafana_mimir_url_configured" => true,
      "inventory_hostname" => "app-001",
      "instance_id" => "i-0abc123",
      "alloy_app_metrics_port" => 4050
    }

    test "empty scrape_app_names (the default) still scrapes any app_name — existing consumers see no behaviour change" do
      rendered =
        render_jinja!(@alloy_path, Map.merge(@base_context, %{"app_name" => "server", "alloy_app_metrics_scrape_app_names" => []}))

      assert rendered =~ "prometheus.scrape \"app\""
      assert_alloy_valid!(rendered)
    end

    test "a non-empty scrape_app_names list scopes OUT an app_name not on it" do
      rendered =
        render_jinja!(
          @alloy_path,
          Map.merge(@base_context, %{
            "app_name" => "server",
            "alloy_app_metrics_scrape_app_names" => ["pipeline", "polling"]
          })
        )

      refute rendered =~ "prometheus.scrape \"app\""
      assert_alloy_valid!(rendered)
    end

    test "a non-empty scrape_app_names list scopes IN an app_name that is on it" do
      rendered =
        render_jinja!(
          @alloy_path,
          Map.merge(@base_context, %{
            "app_name" => "pipeline",
            "alloy_app_metrics_scrape_app_names" => ["pipeline", "polling"]
          })
        )

      assert rendered =~ "prometheus.scrape \"app\""
      assert rendered =~ "\"__address__\" = \"localhost:4050\","
      assert_alloy_valid!(rendered)
    end

    test "node_exporter's :9100 scrape is present and unaffected whether the app is scoped in or out" do
      scoped_out =
        render_jinja!(
          @alloy_path,
          Map.merge(@base_context, %{"app_name" => "server", "alloy_app_metrics_scrape_app_names" => ["pipeline"]})
        )

      scoped_in =
        render_jinja!(
          @alloy_path,
          Map.merge(@base_context, %{"app_name" => "pipeline", "alloy_app_metrics_scrape_app_names" => ["pipeline"]})
        )

      assert scoped_out =~ "\"__address__\" = \"localhost:9100\","
      assert scoped_in =~ "\"__address__\" = \"localhost:9100\","
    end

    test "omitting the variable entirely (no role default injected) still renders the app scrape — undefined behaves as unrestricted" do
      rendered = render_jinja!(@alloy_path, Map.put(@base_context, "app_name", "server"))

      assert rendered =~ "prometheus.scrape \"app\""
      assert_alloy_valid!(rendered)
    end
  end

  # SECTION: grafana-datasources.yaml.j2 — Mimir datasource (raw j2 — structural assertions)

  describe "grafana-datasources.yaml.j2 — Mimir datasource" do
    @datasource_path Path.join(@priv_roles_dir, "grafana_ui/templates/grafana-datasources.yaml.j2")

    test "adds a Mimir prometheus-type datasource under the grafana_mimir_url_configured conditional" do
      content = File.read!(@datasource_path)

      assert content =~ "{% if grafana_mimir_url_configured %}"
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
      mimir_if = :binary.match(content, "{% if grafana_mimir_url_configured %}") |> elem(0)
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

  defp flatten_tasks_for_test(entries) do
    Enum.flat_map(entries, fn
      %{"block" => block} -> flatten_tasks_for_test(block)
      task -> [task]
    end)
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

  # SECTION: alloy validate — the arm that discriminates a syntactically-invalid
  # River config from a substring match that only looked for the right text. Raises
  # loudly (never skips) when the `alloy` binary is absent — reporting a silent
  # substring-only fallback as "verified" is exactly what this exists to prevent.

  defp assert_alloy_valid!(rendered_config) do
    exit_status = alloy_validate_exit_status(rendered_config)

    if exit_status !== 0 do
      raise "alloy validate rejected a render expected to be valid (exit #{exit_status}): #{rendered_config}"
    end

    :ok
  end

  defp alloy_validate_exit_status(rendered_config) do
    tmp_path = Path.join(System.tmp_dir!(), "mimir_role_test_alloy_#{System.unique_integer([:positive])}.alloy")
    File.write!(tmp_path, rendered_config)

    {_output, exit_status} = System.cmd(alloy_binary!(), ["validate", tmp_path], stderr_to_stdout: true)
    File.rm!(tmp_path)

    exit_status
  end

  defp alloy_binary! do
    System.find_executable("alloy") ||
      raise "the alloy CLI was not found on PATH — install it (https://github.com/grafana/alloy, opgg tested v1.19.0) to validate rendered configs for real; a substring-only fallback would not have caught the opgg PR #120 `#`-comment defect class"
  end
end
