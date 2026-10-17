#!/usr/bin/env python3
"""Local-only maintenance regression checks: python3 tests/test_maintenance.py."""

import errno
import json
import os
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
FAKE_KUBECTL = r'''
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['CASE_DIR'])
args = sys.argv[1:]
input_data = sys.stdin.read() if '-i' in args or ('-f' in args and '-' in args) else ''
with (root/'calls').open('a') as f:
    f.write(json.dumps({'args':args,'stdin':input_data})+'\n')
mode = os.environ.get('FAKE_MODE','retry')
if mode in ('retry','always-fail'):
    counter = root/'count'
    n = int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    if n < 3 or mode == 'always-fail':
        print('partial output that must not leak')
        print('context deadline exceeded',file=sys.stderr)
        sys.exit(17)
    print('{"ok":true}')
elif mode == 'vault':
    if 'nodes' in args:
        counter=root/'helper-retries'
        n=int(counter.read_text())+1 if counter.exists() else 1
        counter.write_text(str(n))
        if n < 3:
            print('temporary unseal-helper API failure',file=sys.stderr)
            sys.exit(17)
        print('{"items":[]}')
        sys.exit(0)
    if 'exec' in args:
        command = args[args.index('--')+1:]
        p = subprocess.run(command)
        if p.returncode:
            print('command terminated with exit code '+str(p.returncode),file=sys.stderr)
        sys.exit(p.returncode)
    if 'pods' in args:
        print(json.dumps({'items':[{'metadata':{'name':'vault-0'},'status':{'phase':'Running','conditions':[{'type':'Ready','status':'True'}]}}]}))
    else:
        print(json.dumps({'kind':'StatefulSet','metadata':{'generation':1},'spec':{'replicas':1,'selector':{'matchLabels':{'app':'vault'}}},'status':{'observedGeneration':1,'replicas':1,'readyReplicas':1}}))
elif mode == 'csi':
    if 'pv,pvc,pods' in args:
        print((root/'resources.json').read_text())
    else:
        counter = root/'count'
        n = int(counter.read_text())+1 if counter.exists() else 1
        counter.write_text(str(n))
        data = json.loads((root/'attachments.json').read_text())
        if n > 1:
            for item in data['items']:
                if item['metadata']['name'] != 'held': item['status']['attached']=False
        print(json.dumps(data))
elif mode == 'hpa':
    path=root/'hpa-scenario.json'
    data=json.loads(path.read_text())
    context=args[args.index('--context')+1]
    namespace=args[args.index('-n')+1] if '-n' in args else 'default'
    command=next(a for a in args if a in ('get','patch','scale'))
    resource=args[args.index(command)+1]
    if command=='get' and resource=='hpa':
        print(json.dumps({'items':data['hpas'].get(context,[])}))
    elif command=='patch':
        patch=json.loads(args[args.index('-p')+1])
        obj=next(h for h in data['hpas'][context] if h['metadata']['namespace']==namespace and 'hpa/'+h['metadata']['name']==resource)
        obj['spec'].update(patch['spec'])
        path.write_text(json.dumps(data))
        print(json.dumps(obj))
    else:
        if resource=='pods':
            name=args[args.index('-l')+1].split('=',1)[1]
            obj=next(w for w in data['workloads'] if w['context']==context and w['object']['metadata']['namespace']==namespace and w['object']['metadata']['name']==name)
        else:
            obj=next(w for w in data['workloads'] if w['context']==context and w['object']['metadata']['namespace']==namespace and w['resource']==resource)
        if command=='scale':
            n=int(next(a.split('=')[1] for a in args if a.startswith('--replicas=')))
            obj['object']['spec']['replicas']=n
            obj['object']['metadata']['generation']+=1
            obj['object']['status']={'observedGeneration':obj['object']['metadata']['generation'],'replicas':n,'readyReplicas':n}
            obj['pods']=[{'metadata':{'name':name+'-'+str(i)},'status':{'phase':'Running','conditions':[{'type':'Ready','status':'True'}]}}
                         for i in range(n) for name in [obj['object']['metadata']['name']]]
            path.write_text(json.dumps(data))
        elif resource=='pods':
            obj['podReads']=obj.get('podReads',0)+1
            if obj.get('healthyAfter') and obj['podReads']>=obj['healthyAfter']:
                n=obj['object']['spec']['replicas']
                obj['object']['status']['readyReplicas']=n
                obj['pods']=[{'metadata':{'name':name+'-'+str(i)},'status':{'phase':'Running','conditions':[{'type':'Ready','status':'True'}]}}
                             for i in range(n) for name in [obj['object']['metadata']['name']]]
            path.write_text(json.dumps(data))
            print(json.dumps({'items':obj['pods']}))
        else:
            print(json.dumps(obj['object']))
else:
    raise SystemExit('Unexpected mock mode: '+mode)
'''


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="maintenance-tests-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "kubectl").write_text(f"#!{sys.executable}\n" + FAKE_KUBECTL)
        (self.path / "kubectl").chmod(0o755)
        (self.path / "vault").write_text(
            f"#!{sys.executable}\nimport json,os,pathlib,sys\n"
            "sealed=(pathlib.Path(os.environ['CASE_DIR'])/'sealed').exists()\n"
            "print(json.dumps({'initialized':True,'sealed':sealed}))\n"
            "sys.exit(2 if sealed else 0)\n"
        )
        (self.path / "vault").chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
            "CASE_DIR": str(self.path),
            "TMPDIR": str(self.path),
            "MAINTENANCE_STATE": str(self.path / "journal.json"),
            "TIMEOUT": "10",
            "POLL_INTERVAL": "1",
        }
        self.source = "source " + shlex.quote(str(ROOT / "scripts/drainall.sh")) + "; "

    def shell(self, code, *, mode="retry", success=True, timeout=30):
        result = subprocess.run(
            ["/bin/bash", "-c", self.source + code], cwd=ROOT,
            env={**self.env, "FAKE_MODE": mode}, capture_output=True,
            text=True, timeout=timeout, check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self):
        path = self.path / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_context_and_color_format(self):
        result = self.shell("resource_log 'Scaling down' homelab monitoring deployment/example ' from 1 to 0...'; phase_log up homelab observability 0")
        lines = result.stdout.splitlines()
        timestamp = r"\x1b\[1;37m\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [AP]M\]\x1b\[0m "
        self.assertRegex(lines[0], timestamp + r"homelab: Scaling down \x1b\[1;36mmonitoring\x1b\[0m:\x1b\[1;33mdeployment/example\x1b\[0m from 1 to 0\.\.\.$")
        self.assertRegex(lines[1], timestamp + r"homelab: Scaling up \x1b\[1;35mobservability\x1b\[0m \(phase 0\)\.\.\.$")
        self.assertNotIn("[homelab]", result.stdout)

    def test_retries_discard_partial_output_and_delay_twice(self):
        result = self.shell('sleep() { printf "%s\\n" "$1" >> "$CASE_DIR/delays"; }; kube homelab get nodes -o json')
        self.assertEqual(json.loads(result.stdout), {"ok": True})
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual((self.path / "delays").read_text().splitlines(), ["5", "5"])
        self.assertIn("homelab: Retrying kubectl in 5 seconds", ANSI.sub("", result.stderr))

    def test_retries_replay_apply_stdin(self):
        result = self.shell('sleep() { :; }; printf \'{"kind":"ConfigMap","data":{"x":"y"}}\\n\' | kube homelab apply -f -')
        self.assertEqual(json.loads(result.stdout), {"ok": True})
        inputs = [call["stdin"] for call in self.calls()]
        self.assertEqual(len(inputs), 3)
        self.assertEqual(inputs, [inputs[0]] * 3)
        self.assertEqual(json.loads(inputs[0])["data"], {"x": "y"})

    def test_three_failures_return_original_error(self):
        result = self.shell("sleep() { :; }; kube rancher get nodes -o json", mode="always-fail", success=False)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual(result.stdout, "")

    def test_sealed_vault_is_not_a_kubectl_failure(self):
        (self.path / "sealed").touch()
        result = self.shell("if vault_unsealed homelab vault statefulset/vault 1; then exit 1; fi", mode="vault")
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(result.stderr, "")
        self.assertIn("sh", self.calls()[0]["args"])

    def test_background_unseal_runs_and_readiness_waits_for_it(self):
        (self.path / "sealed").touch()
        (self.path / "unseal.sh").write_text('kubectl --context homelab get nodes >/dev/null || exit 99\nprintf called > "$CASE_DIR/helper-called"\ncommand sleep .1\nrm "$CASE_DIR/sealed"\n')
        result = self.shell('sleep() { if [[ "$1" != 5 ]]; then command sleep "$@"; fi; }; SCRIPT_DIR="$CASE_DIR"; install_handlers; wait_workload homelab vault statefulset/vault 1', mode="vault")
        self.assertTrue((self.path / "helper-called").exists())
        self.assertFalse((self.path / "sealed").exists())
        self.assertIn("Starting scripts/unseal.sh in the background", result.stdout)
        self.assertIn("Finished vault:statefulset/vault", ANSI.sub("", result.stdout))
        self.assertNotIn("command terminated", result.stderr)
        self.assertEqual((self.path / "helper-retries").read_text(), "3")

    def test_already_unsealed_vault_does_not_run_helper(self):
        (self.path / "unseal.sh").write_text('touch "$CASE_DIR/unexpected-helper"\nexit 99\n')
        self.shell('SCRIPT_DIR="$CASE_DIR"; install_handlers; wait_workload homelab vault statefulset/vault 1', mode="vault")
        self.assertFalse((self.path / "unexpected-helper").exists())

    def test_background_unseal_failure_is_reported(self):
        (self.path / "sealed").touch()
        (self.path / "unseal.sh").write_text('printf "PKI unavailable\\n" >&2\nexit 7\n')
        result = self.shell('SCRIPT_DIR="$CASE_DIR"; install_handlers; wait_workload homelab vault statefulset/vault 1', mode="vault", success=False)
        self.assertIn("Automatic Vault unsealing failed (exit 7)", result.stderr)
        self.assertIn("PKI unavailable", result.stderr)
        self.assertNotIn("Finished", result.stdout)

    def csi_fixture(self):
        resources = {"items": [
            {"kind": "PersistentVolumeClaim", "metadata": {"name": "textfile", "namespace": "monitoring"}, "spec": {"volumeName": "held-pv"}},
            {"kind": "Pod", "metadata": {"name": "exporter", "namespace": "monitoring", "ownerReferences": [{"kind": "DaemonSet"}]},
             "spec": {"nodeName": "node1", "volumes": [{"persistentVolumeClaim": {"claimName": "textfile"}}]}, "status": {"phase": "Running"}},
            {"kind": "Pod", "metadata": {"name": "old-exporter", "namespace": "monitoring"},
             "spec": {"nodeName": "node2", "volumes": [{"persistentVolumeClaim": {"claimName": "textfile"}}]}, "status": {"phase": "Succeeded"}},
        ]}
        attachments = {"items": [
            {"metadata": {"name": name}, "spec": {"nodeName": node, "source": {"persistentVolumeName": pv}}, "status": {"attached": attached}}
            for name, node, pv, attached in (
                ("held", "node1", "held-pv", True),
                ("other-node", "node2", "held-pv", True),
                ("unused", "node1", "unused-pv", True),
                ("detached", "node1", "detached-pv", False),
            )
        ]}
        (self.path / "resources.json").write_text(json.dumps(resources))
        (self.path / "attachments.json").write_text(json.dumps(attachments))

    def test_csi_retained_consumers_are_matched_per_node(self):
        self.csi_fixture()
        result = self.shell('resources=$(< "$CASE_DIR/resources.json"); attachment_consumers "$resources" < "$CASE_DIR/attachments.json"')
        data = json.loads(result.stdout)
        self.assertEqual([row["name"] for row in data["retained"]], ["held"])
        self.assertEqual([row["name"] for row in data["waiting"]], ["other-node", "unused"])

    def test_csi_wait_finishes_with_retained_daemonset_attachment(self):
        self.csi_fixture()
        result = self.shell("install_handlers; wait_storage_detach", mode="csi")
        self.assertIn("Retaining monitoring:volumeattachment/held", ANSI.sub("", result.stdout))
        self.assertIn("Unused CSI volumes have detached", result.stdout)
        self.assertTrue(all("get" in call["args"] for call in self.calls()))
        self.assertEqual((self.path / "count").read_text(), "2")

    def test_resume_plans_prefer_homelab_and_accept_explicit_cluster(self):
        for script, target, first_context in (
            ("uncordon", "policyreporter", "homelab"),
            ("uncordon", "rancher:certmanager", "rancher"),
            ("drainall", "policyreporter", "homelab"),
            ("drainall", "rancher:certmanager", "rancher"),
        ):
            with self.subTest(script=script, target=target):
                result = subprocess.run(["/bin/bash", str(ROOT / f"scripts/{script}.sh"), "--plan", target], env=self.env, capture_output=True, text=True, timeout=20, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                first = ANSI.sub("", result.stdout).splitlines()[1]
                self.assertIn(f"] {first_context}: ", first)
                self.assertIn(target.split(":")[-1] + ", phase", first)
        self.assertEqual(self.calls(), [])

    def test_invalid_resume_target_fails_before_api_calls(self):
        for target in ("not-a-target", "wrong:policyreporter", "rancher:opencode"):
            result = self.shell(f"initialize; parse_arguments {shlex.quote(target)}", success=False)
            self.assertRegex(result.stderr, "Invalid resume target|Resume context")
        self.assertEqual(self.calls(), [])

    def test_group_resume_includes_all_target_phases_in_direction_order(self):
        rows = [
            {"context": context, "namespace": stage, "stage": stage, "rank": rank, "phase": phase, "resource": f"deployment/{stage}-{phase}", "replicas": 1}
            for context in ("homelab", "rancher")
            for stage, rank, phases in (("earlier", 0, (0,)), ("target", 1, (0, 1)), ("later", 2, (0,)))
            for phase in phases
        ]
        (self.path / "workloads.json").write_text(json.dumps(rows))
        setup = '''WORKLOADS=$(< "$CASE_DIR/workloads.json"); STATE='{"downCompleted":[]}';
set_replicas() { printf '%s %s\n' "$1" "$3" >> "$CASE_DIR/scaled"; };
wait_workload() { :; }; group_webhook_policy() { :; }; prepare_restore_group() { RESTORE_GROUP=$1; };
'''
        self.shell(setup + 'parse_arguments target; run_groups up rancher; run_groups up homelab')
        self.assertEqual((self.path / "scaled").read_text().splitlines(), [
            "homelab deployment/target-0", "homelab deployment/target-1", "homelab deployment/later-0",
        ])
        (self.path / "scaled").unlink()
        self.shell(setup + 'parse_arguments target; run_groups down homelab; run_groups down rancher')
        self.assertEqual((self.path / "scaled").read_text().splitlines()[:3], [
            "homelab deployment/target-1", "homelab deployment/target-0", "homelab deployment/earlier-0",
        ])

    def test_resume_entrypoints_skip_earlier_cluster_and_preserve_snapshot(self):
        rows = [
            {"context": context, "namespace": "example", "stage": stage, "rank": rank,
             "phase": phase, "resource": f"deployment/{stage}-{phase}", "replicas": 3}
            for context in ("homelab", "rancher")
            for stage, rank, phases in (("earlier", 0, (0,)), ("target", 1, (0, 1)), ("later", 2, (0,)))
            for phase in phases
        ]
        journal = {"version": 1, "status": "draining", "workloads": rows, "contexts": {
            c: {"nodes": [], "webhooks": [], "hpas": [], "cronjobs": []}
            for c in ("homelab", "rancher", "xdev", "xtest")
        }, "downCompleted": [], "gateways": []}
        (self.path / "journal.json").write_text(json.dumps(journal))
        (self.path / "workloads.json").write_text(json.dumps(rows))
        setup = '''initialize() { WORKLOADS=$(< "$CASE_DIR/workloads.json"); };
restore_nodes() { printf 'nodes:%s\n' "$1" >> "$CASE_DIR/actions"; };
webhook_policy() { printf 'webhook:%s\n' "$1" >> "$CASE_DIR/actions"; };
restore_auxiliary() { printf 'aux:%s\n' "$1" >> "$CASE_DIR/actions"; };
restore_gateways() { :; }; group_webhook_policy() { :; }; prepare_restore_group() { RESTORE_GROUP=$1; };
set_replicas() { printf 'scale:%s:%s:%s\n' "$1" "$3" "$4" >> "$CASE_DIR/actions"; };
wait_workload() { :; };
'''
        self.shell(setup + 'uncordon_main target')
        actions = (self.path / "actions").read_text().splitlines()
        self.assertIn("nodes:homelab", actions)
        self.assertNotIn("nodes:rancher", actions)
        self.assertNotIn("aux:rancher", actions)
        self.assertEqual([a for a in actions if a.startswith("scale:")], [
            "scale:homelab:deployment/target-0:3", "scale:homelab:deployment/target-1:3", "scale:homelab:deployment/later-0:3",
        ])
        self.assertEqual(json.loads((self.path / "journal.json").read_text())["workloads"], rows)

        journal["status"] = "draining"
        (self.path / "journal.json").write_text(json.dumps(journal))
        (self.path / "actions").unlink()
        setup += '''capture_state() { die 'Must not recapture on resume'; };
suspend_cronjobs() { printf 'cron:%s\n' "$1" >> "$CASE_DIR/actions"; };
pin_hpas() { :; };
verify_stopped() { printf 'verify:%s\n' "$1" >> "$CASE_DIR/actions"; };
cordon_nodes() { printf 'cordon:%s\n' "$1" >> "$CASE_DIR/actions"; };
'''
        self.shell(setup + 'printf "drainall\\n" | drainall_main rancher:target')
        actions = (self.path / "actions").read_text().splitlines()
        self.assertEqual([a for a in actions if a.startswith("scale:")], [
            "scale:rancher:deployment/target-1:0", "scale:rancher:deployment/target-0:0", "scale:rancher:deployment/earlier-0:0",
        ])
        self.assertFalse(any(":homelab" in a or ":xdev" in a or ":xtest" in a for a in actions))
        self.assertEqual(json.loads((self.path / "journal.json").read_text())["workloads"], rows)

    def hpa_fixture(self, *, minimum=1, current=1, ready=None, captured=2, kind="Deployment", saved=None):
        ready = current if ready is None else ready
        name = "gitlab-sidekiq-default-v2"
        resource = kind.lower() + "/" + name
        hpa = {"metadata": {"name": "autoscaler", "namespace": "gitlab"}, "spec": {
            "scaleTargetRef": {"apiVersion": "apps/v1", "kind": kind, "name": name}, "maxReplicas": 5,
        }}
        if minimum is not None:
            hpa["spec"]["minReplicas"] = minimum
        scenario = {"hpas": {"homelab": [hpa]}, "workloads": [{
            "context": "homelab", "resource": resource,
            "object": {"kind": kind, "metadata": {"name": name, "namespace": "gitlab", "generation": 1},
                       "spec": {"replicas": current, "selector": {"matchLabels": {"app": name}}},
                       "status": {"replicas": current, "readyReplicas": ready, "observedGeneration": 1}},
            "pods": [{"metadata": {"name": name + "-" + str(i)}, "status": {
                "phase": "Running" if i < ready else "Pending", "conditions": [{"type": "Ready", "status": "True" if i < ready else "False"}],
            }} for i in range(current)],
        }]}
        rows = [{"context": "homelab", "namespace": "gitlab", "stage": "gitlab", "rank": 1,
                 "phase": 1, "resource": resource, "replicas": captured}]
        journal = {"version": 1, "workloads": rows, "downCompleted": [], "contexts": {
            "homelab": {"hpas": saved or [], "webhooks": []},
        }}
        (self.path / "hpa-scenario.json").write_text(json.dumps(scenario))
        (self.path / "workloads.json").write_text(json.dumps(rows))
        (self.path / "journal.json").write_text(json.dumps(journal))
        return scenario, resource

    def run_hpa_group(self, direction="up", extra=""):
        return self.shell('WORKLOADS=$(< "$CASE_DIR/workloads.json"); STATE=$(< "$CASE_DIR/journal.json"); '
                          'install_handlers; run_groups ' + direction + ' homelab; ' + extra, mode="hpa")

    def test_new_live_hpa_minimum_replaces_captured_count(self):
        self.hpa_fixture(minimum=1, current=1, captured=2)
        result = self.run_hpa_group(extra='printf "%s" "$WORKLOADS" > "$CASE_DIR/after.json"')
        self.assertIn("HPA minimum 1 healthy replicas satisfied", result.stdout)
        self.assertFalse(any("scale" in c["args"] for c in self.calls()))
        self.assertTrue(any("hpa" in c["args"] and "-A" in c["args"] for c in self.calls()))
        self.assertEqual(json.loads((self.path / "after.json").read_text())[0]["replicas"], 2)

    def test_hpa_above_minimum_keeps_count_and_accepts_extra_unready_pods(self):
        scenario, _ = self.hpa_fixture(minimum=2, current=3, ready=2, captured=4)
        scenario["workloads"][0]["pods"].append({"metadata": {"deletionTimestamp": "now"}, "status": {
            "phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
        }})
        (self.path / "hpa-scenario.json").write_text(json.dumps(scenario))
        result = self.run_hpa_group()
        self.assertIn("Keeping gitlab:deployment/gitlab-sidekiq-default-v2 at 3 replicas", ANSI.sub("", result.stdout))
        self.assertFalse(any("scale" in c["args"] for c in self.calls()))

    def test_legacy_hpa_pin_is_removed_before_scaling_to_original_minimum(self):
        saved = [{"namespace": "gitlab", "resource": "hpa/autoscaler", "target": "deployment/gitlab-sidekiq-default-v2", "minReplicas": 1, "maxReplicas": 5}]
        scenario, _ = self.hpa_fixture(minimum=2, current=0, captured=2, saved=saved)
        scenario["hpas"]["homelab"][0]["spec"]["maxReplicas"] = 2
        (self.path / "hpa-scenario.json").write_text(json.dumps(scenario))
        self.run_hpa_group()
        calls = self.calls()
        patch_index = next(i for i, c in enumerate(calls) if "patch" in c["args"])
        scale_index = next(i for i, c in enumerate(calls) if "scale" in c["args"])
        self.assertLess(patch_index, scale_index)
        self.assertIn("--replicas=1", calls[scale_index]["args"])
        state = json.loads((self.path / "hpa-scenario.json").read_text())
        self.assertEqual(state["hpas"]["homelab"][0]["spec"]["minReplicas"], 1)
        self.assertEqual(state["hpas"]["homelab"][0]["spec"]["maxReplicas"], 5)

    def test_hpa_scales_only_to_minimum_and_supports_statefulsets(self):
        self.hpa_fixture(minimum=2, current=0, captured=4, kind="StatefulSet")
        self.run_hpa_group()
        scales = [c for c in self.calls() if "scale" in c["args"]]
        self.assertEqual(len(scales), 1)
        self.assertIn("--replicas=2", scales[0]["args"])

    def test_hpa_missing_minimum_defaults_to_one(self):
        self.hpa_fixture(minimum=None, current=0, captured=4)
        self.run_hpa_group()
        scales = [c for c in self.calls() if "scale" in c["args"]]
        self.assertEqual(len(scales), 1)
        self.assertIn("--replicas=1", scales[0]["args"])

    def test_hpa_zero_minimum_does_not_wake_workload(self):
        self.hpa_fixture(minimum=0, current=0, captured=4)
        self.run_hpa_group()
        self.assertFalse(any("scale" in c["args"] for c in self.calls()))

    def test_hpa_wait_rejects_terminating_pods_below_healthy_minimum(self):
        scenario, _ = self.hpa_fixture(minimum=2, current=2, ready=2)
        workload = scenario["workloads"][0]
        workload["pods"][1]["metadata"]["deletionTimestamp"] = "now"
        workload["healthyAfter"] = 2
        (self.path / "hpa-scenario.json").write_text(json.dumps(scenario))
        self.run_hpa_group()
        pods_reads = [c for c in self.calls() if "pods" in c["args"]]
        self.assertGreaterEqual(len(pods_reads), 2)

    def test_unrelated_hpas_do_not_override_fixed_workload(self):
        scenario, _ = self.hpa_fixture(minimum=1, current=0, captured=3)
        scenario["hpas"]["rancher"] = json.loads(json.dumps(scenario["hpas"]["homelab"]))
        scenario["hpas"]["homelab"][0]["metadata"]["namespace"] = "other"
        (self.path / "hpa-scenario.json").write_text(json.dumps(scenario))
        self.run_hpa_group()
        scales = [c for c in self.calls() if "scale" in c["args"]]
        self.assertEqual(len(scales), 1)
        self.assertIn("--replicas=3", scales[0]["args"])

    def test_fixed_workload_readiness_still_requires_exact_count(self):
        self.hpa_fixture(current=1, ready=1, captured=2)
        result = self.shell('TIMEOUT=1; install_handlers; wait_workload homelab gitlab deployment/gitlab-sidekiq-default-v2 2', mode="hpa", success=False)
        self.assertIn("Timed out", result.stderr)

    def test_hpa_workload_shutdown_still_requires_zero(self):
        self.hpa_fixture(minimum=1, current=2, captured=2)
        self.run_hpa_group("down")
        scales = [c for c in self.calls() if "scale" in c["args"]]
        self.assertEqual(len(scales), 1)
        self.assertIn("--replicas=0", scales[0]["args"])
        self.assertFalse(any("hpa" in c["args"] for c in self.calls()))

    def run_interrupt(self, *, abort):
        code = self.source + '''install_handlers; STATE='{"downCompleted":[]}';
long_wait() { command sh -c 'printf "WORKER_STARTED %s\\n" "$$"; while :; do sleep 1; done'; };
waiting_step homelab 'test wait' long_wait; printf 'AFTER_WAIT skipped=%s\\n' "$SKIPPED_WAIT_COUNT"'''
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execve("/bin/bash", ["/bin/bash", "-c", code], self.env)
        output = bytearray()
        original_terminal = termios.tcgetattr(fd)

        def until(needle, timeout=10):
            deadline = time.monotonic() + timeout
            while needle not in output:
                if time.monotonic() >= deadline:
                    self.fail("PTY timed out: " + output.decode(errors="replace"))
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO: break
                        raise
                    if not chunk: break
                    output.extend(chunk)

        try:
            until(b"WORKER_STARTED")
            os.write(fd, b"\x03")
            until(b"Press Enter to skip")
            self.assertIn(b"Press Enter to skip", output)
            os.write(fd, b"\x03" if abort else b"\n")
            if not abort:
                until(b"AFTER_WAIT")
            deadline = time.monotonic() + 10
            while True:
                # Drain the PTY while waiting: macOS stty restores terminal
                # settings with TCSADRAIN and can wait for unread output.
                if select.select([fd], [], [], 0.05)[0]:
                    try: output.extend(os.read(fd, 65536))
                    except OSError as exc:
                        if exc.errno != errno.EIO: raise
                finished, status = os.waitpid(pid, os.WNOHANG)
                if finished: break
                if time.monotonic() >= deadline: self.fail("Script did not exit after interrupt")
                time.sleep(0.05)
            exitcode = os.waitstatus_to_exitcode(status)
            self.assertEqual(exitcode, 130 if abort else 0, output.decode(errors="replace"))
            terminal_flags = termios.ECHO | termios.ICANON | termios.ISIG
            self.assertEqual(termios.tcgetattr(fd)[3] & terminal_flags, original_terminal[3] & terminal_flags)
            if abort:
                self.assertNotIn(b"AFTER_WAIT", output)
            else:
                self.assertIn(b"skipped=1", output)
                journal = json.loads((self.path / "journal.json").read_text())
                self.assertEqual(journal["skippedWaits"], [{"context": "homelab", "step": "test wait"}])
            worker = re.search(rb"WORKER_STARTED (\d+)", output)
            self.assertIsNotNone(worker)
            worker_status = subprocess.run(["ps", "-p", worker[1].decode(), "-o", "stat="], capture_output=True, text=True, check=False)
            self.assertTrue(not worker_status.stdout.strip() or worker_status.stdout.strip().startswith("Z"), "Wait worker survived interrupt: " + worker_status.stdout)
        finally:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
            os.close(fd)

    def test_ctrl_c_enter_skips_only_wait(self):
        self.run_interrupt(abort=False)

    def test_second_ctrl_c_aborts(self):
        self.run_interrupt(abort=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
