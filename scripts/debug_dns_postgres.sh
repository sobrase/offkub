#!/usr/bin/env bash
# Debug "cannot resolve postgres": gather runtime evidence and write NDJSON to the debug log path.
# Run from repo root with KUBECONFIG pointing at the cluster.
set -euo pipefail
LOG_PATH="${1:-/home/tglr/Dev/git/offkub/.cursor/debug-351bb9.log}"
SESSION_ID="${2:-351bb9}"
KUBECONFIG="${KUBECONFIG:-}"
if [[ -z "$KUBECONFIG" ]]; then
  echo "Set KUBECONFIG (e.g. export KUBECONFIG=/path/to/admin.conf)" >&2
  exit 1
fi
export KUBECONFIG

append_log() {
  python3 -c "
import json,sys,time
obj=json.load(sys.stdin)
obj['sessionId']='$SESSION_ID'
obj['timestamp']=int(time.time()*1000)
obj.setdefault('location','debug_dns_postgres.sh')
print(json.dumps(obj))
" >> "$LOG_PATH"
}

# Hypothesis A: CoreDNS pods not running or not Ready
coredns_json=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o json 2>/dev/null || echo '{"items":[]}')
echo "{\"hypothesisId\":\"A\",\"message\":\"CoreDNS pods status\",\"data\":$(echo "$coredns_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=d.get('items',[])
out={'total':len(items),'ready':0,'pods':[]}
for p in items:
    ready=next((s['status']=='True' for s in p.get('status',{}).get('conditions',[]) if s.get('type')=='Ready'), False)
    if ready: out['ready']+=1
    out['pods'].append({'name':p['metadata']['name'],'phase':p.get('status',{}).get('phase'),'podIP':p.get('status',{}).get('podIP'),'ready':ready})
print(json.dumps(out))
")}" | append_log

# Hypothesis B: Service "postgres" missing or wrong namespace; H: postgres has endpoints
postgres_svc_json=$(kubectl get svc -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[i for i in d.get('items',[]) if i.get('metadata',{}).get('name')=='postgres']
print(json.dumps([{'namespace':i['metadata']['namespace'],'name':i['metadata']['name'],'clusterIP':i.get('spec',{}).get('clusterIP'),'type':i.get('spec',{}).get('type')} for i in items]))
" 2>/dev/null || echo "[]")
kube_dns_ip=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
echo "{\"hypothesisId\":\"B\",\"message\":\"Service postgres and kube-dns\",\"data\":{\"postgres_services\":$postgres_svc_json,\"kube_dns_clusterIP\":\"$kube_dns_ip\"}}" | append_log

postgres_ep=$(kubectl get endpoints -n ares postgres -o json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    subs=d.get('subsets',[])
    addrs=sum((s.get('addresses',[]) for s in subs),[])
    print(json.dumps({'has_endpoints':len(addrs)>0,'address_count':len(addrs)}))
except Exception:
    print(json.dumps({'has_endpoints':False,'error':'no endpoints or resource'}))
" 2>/dev/null || echo '{"has_endpoints":false}')
echo "{\"hypothesisId\":\"H\",\"message\":\"postgres service endpoints (ares)\",\"data\":$postgres_ep}" | append_log

# Hypothesis C/D/E: nslookup from default namespace
NS=default
POD=debug-dns-$$
kubectl run "$POD" --image=registry.local:5000/python:3.12-alpine --restart=Never -n "$NS" -- sleep 300 2>/dev/null || true
kubectl wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=60s 2>/dev/null || true

# Hypothesis I: pod resolv.conf (nameserver correct?)
resolv_conf=$(kubectl exec "$POD" -n "$NS" -- cat /etc/resolv.conf 2>/dev/null || echo "failed")
pod_node=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
echo "{\"hypothesisId\":\"I\",\"message\":\"resolv.conf and pod node\",\"data\":{\"resolv_conf\":$(echo "$resolv_conf" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"pod_node\":\"$pod_node\"}}" | append_log

# Hypothesis J: raw UDP from pod to kube-dns IP:53 (connectivity, not resolution)
dns_ip="${kube_dns_ip:-10.96.0.10}"
udp_test=$(kubectl exec "$POD" -n "$NS" -- python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.sendto(b'\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01', (\"$dns_ip\", 53))
    s.recvfrom(1024)
    print('reply_ok')
except socket.timeout:
    print('timeout')
except Exception as e:
    print('error:'+str(e))
" 2>&1 || echo "exec_failed")
echo "{\"hypothesisId\":\"J\",\"message\":\"pod UDP to kube-dns :53\",\"data\":{\"dns_ip\":\"$dns_ip\",\"result\":$(echo "$udp_test" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}}" | append_log

nslookup_postgres=$(kubectl exec "$POD" -n "$NS" -- nslookup postgres 2>&1 || true)
nslookup_postgres_fqdn=$(kubectl exec "$POD" -n "$NS" -- nslookup postgres.default.svc.cluster.local 2>&1 || true)
nslookup_kubernetes=$(kubectl exec "$POD" -n "$NS" -- nslookup kubernetes.default.svc.cluster.local 2>&1 || true)
dns_policy=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.dnsPolicy}' 2>/dev/null || echo "")

echo "{\"hypothesisId\":\"C\",\"message\":\"nslookup postgres (short) from default\",\"data\":{\"output\":$(echo "$nslookup_postgres" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"dnsPolicy\":\"$dns_policy\",\"pod_namespace\":\"$NS\"}}" | append_log
echo "{\"hypothesisId\":\"D\",\"message\":\"nslookup postgres.default from default\",\"data\":{\"output\":$(echo "$nslookup_postgres_fqdn" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}" | append_log
echo "{\"hypothesisId\":\"E\",\"message\":\"nslookup kubernetes (sanity)\",\"data\":{\"output\":$(echo "$nslookup_kubernetes" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}" | append_log

kubectl delete pod "$POD" -n "$NS" --force --grace-period=0 2>/dev/null || true

# Hypothesis F: from namespace ares (same as postgres), short name "postgres" should resolve
ARES_NS=ares
POD2=debug-dns-ares-$$
kubectl get namespace "$ARES_NS" &>/dev/null && {
  kubectl run "$POD2" --image=registry.local:5000/python:3.12-alpine --restart=Never -n "$ARES_NS" -- sleep 300 2>/dev/null || true
  kubectl wait --for=condition=Ready "pod/$POD2" -n "$ARES_NS" --timeout=60s 2>/dev/null || true
  nslookup_postgres_ares=$(kubectl exec "$POD2" -n "$ARES_NS" -- nslookup postgres 2>&1 || true)
  nslookup_postgres_ares_fqdn=$(kubectl exec "$POD2" -n "$ARES_NS" -- nslookup postgres.ares.svc.cluster.local 2>&1 || true)
  echo "{\"hypothesisId\":\"F\",\"message\":\"nslookup postgres (short) from ares ns\",\"data\":{\"output\":$(echo "$nslookup_postgres_ares" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"pod_namespace\":\"$ARES_NS\"}}" | append_log
  echo "{\"hypothesisId\":\"F\",\"message\":\"nslookup postgres.ares.svc.cluster.local from ares\",\"data\":{\"output\":$(echo "$nslookup_postgres_ares_fqdn" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}" | append_log
  kubectl delete pod "$POD2" -n "$ARES_NS" --force --grace-period=0 2>/dev/null || true
} || echo "{\"hypothesisId\":\"F\",\"message\":\"namespace ares missing\",\"data\":{\"skipped\":true}}" | append_log

# Hypothesis G: which namespace does the failing client (e.g. ares-worker) run in?
worker_pods=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[p for p in d.get('items',[]) if 'worker' in p.get('metadata',{}).get('name','').lower() or (p.get('metadata',{}).get('labels') or {}).get('app')=='worker']
print(json.dumps([{'namespace':p['metadata']['namespace'],'name':p['metadata']['name']} for p in items[:5]]))
" 2>/dev/null || echo "[]")
echo "{\"hypothesisId\":\"G\",\"message\":\"worker-like pods namespace\",\"data\":{\"pods\":$worker_pods}}" | append_log

# Hypothesis N: which nodes run Calico (Felix)? If first master has no calico-node, it has no cali-FORWARD -> DNS works there; workers have cali-FORWARD at 1 -> DNS fails.
calico_nodes_json=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
# calico-node (Felix) is usually in calico-system or kube-system, name like calico-node-xxx
items=[p for p in d.get('items',[]) if 'calico-node' in p.get('metadata',{}).get('name','') or (p.get('metadata',{}).get('labels') or {}).get('k8s-app')=='calico-node']
nodes=[p.get('spec',{}).get('nodeName','') for p in items if p.get('spec',{}).get('nodeName')]
print(json.dumps({'calico_node_pods':[{'name':p['metadata']['name'],'namespace':p['metadata'].get('namespace',''),'node':p.get('spec',{}).get('nodeName','')} for p in items],'nodes_with_calico':sorted(set(nodes))}))
" 2>/dev/null || echo '{"calico_node_pods":[],"nodes_with_calico":[]}')
echo "{\"hypothesisId\":\"N\",\"message\":\"nodes running Calico (calico-node) vs test pod node\",\"data\":{\"calico\":$calico_nodes_json,\"test_pod_node\":\"$pod_node\"}}" | append_log

# Hypothesis K: from first master (host), can we reach kube-dns and a CoreDNS pod on :53?
coredns_one_ip=$(echo "$coredns_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[p.get('status',{}).get('podIP') for p in d.get('items',[]) if p.get('status',{}).get('podIP')]
print(items[0] if items else '')
" 2>/dev/null)
host_nc_dns=$(timeout 2 bash -c "echo -n '' | nc -u -w1 $kube_dns_ip 53 2>&1; echo exit:\$?" || true)
host_nc_pod=$(timeout 2 bash -c "echo -n '' | nc -u -w1 ${coredns_one_ip:-invalid} 53 2>&1; echo exit:\$?" || true)
echo "{\"hypothesisId\":\"K\",\"message\":\"host UDP to kube-dns and coredns pod\",\"data\":{\"host_nc_to_dns\":\"${host_nc_dns:-none}\",\"host_nc_to_pod\":\"${host_nc_pod:-none}\",\"coredns_pod_ip\":\"${coredns_one_ip:-none}\"}}" | append_log

# Hypothesis L: FORWARD chain first rules (on first master)
forward_rules=$(iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"iptables_failed"')
echo "{\"hypothesisId\":\"L\",\"message\":\"FORWARD chain (first 20 lines) on first master\",\"data\":{\"forward_preview\":$forward_rules}}" | append_log

# Hypothesis M: kube-proxy pods running
kpx_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=d.get('items',[])
running=sum(1 for p in items if p.get('status',{}).get('phase')=='Running')
print(json.dumps({'total':len(items),'running':running}))
" 2>/dev/null || echo '{"total":0}')
echo "{\"hypothesisId\":\"M\",\"message\":\"kube-proxy pods\",\"data\":$kpx_pods}" | append_log

echo "Debug output written to $LOG_PATH"
