#!/usr/bin/env bash
# TE 578/778 - environment check. Run as your normal user (it will sudo where needed):
#   bash check_env.sh
# Every line should say OK before Lab 1.

RYU_VENV=${RYU_VENV:-$HOME/ryu-venv}
pass=0; fail=0
ok()  { printf "  [ OK ] %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  [FAIL] %s\n         -> %s\n" "$1" "$2"; fail=$((fail+1)); }

echo "== System"
. /etc/os-release; echo "  $PRETTY_NAME, $(uname -m), $(nproc) CPUs, $(free -g | awk '/Mem/{print $2}') GB RAM"

echo "== Mininet / Open vSwitch"
command -v mn >/dev/null && ok "mininet $(mn --version 2>/dev/null)" || bad "mininet missing" "sudo apt install mininet"
command -v ovs-vsctl >/dev/null && ok "$(ovs-vsctl --version | head -1)" || bad "OVS missing" "sudo apt install openvswitch-switch"
sudo ovs-vsctl show >/dev/null 2>&1 && ok "ovs-vswitchd running" || bad "OVS not running" "sudo systemctl enable --now openvswitch-switch"
if sudo mn --switch ovsbr --controller none --test pingall 2>&1 | grep -q "0% dropped"; then
  ok "mininet pingall (kernel datapath)"
else
  bad "mininet pingall failed" "see Troubleshooting in Setup-Guide.md"
fi
sudo mn -c >/dev/null 2>&1
if sudo ss -ltnp 2>/dev/null | grep -q ":6653 "; then
  bad "something already listens on TCP 6653" "sudo ss -ltnp | grep 6653 ; e.g. sudo systemctl disable --now openvswitch-testcontroller"
else
  ok "TCP 6653 free for the controller"
fi

echo "== Ryu (Python 3.9 venv at $RYU_VENV)"
if [ -x "$RYU_VENV/bin/ryu-manager" ]; then
  v=$("$RYU_VENV/bin/ryu-manager" --version 2>&1 | tail -1)
  [[ "$v" == *4.34* ]] && ok "$v" || bad "unexpected ryu version: $v" "re-run the Ryu install steps"
  "$RYU_VENV/bin/python" -c "import ryu.app.simple_switch_13, ryu.app.ofctl_rest" 2>/dev/null \
    && ok "ryu apps import cleanly" || bad "ryu import error" "pin eventlet==0.30.2 inside the venv"
else
  bad "ryu-manager not found in $RYU_VENV" "see section 4 of Setup-Guide.md"
fi

echo "== Tools"
for t in tshark wireshark iperf iperf3 curl ethtool; do
  command -v $t >/dev/null && ok "$t" || bad "$t missing" "sudo apt install $t"
done

echo "== Docker"
if command -v docker >/dev/null; then
  ok "$(docker --version)"
  docker compose version >/dev/null 2>&1 && ok "$(docker compose version)" || bad "compose v2 missing" "install docker-compose-plugin"
  docker run --rm hello-world >/dev/null 2>&1 && ok "docker run works without sudo" \
    || bad "docker run failed" "sudo usermod -aG docker \$USER, then log out and in"
else
  bad "docker missing" "curl -fsSL https://get.docker.com | sh"
fi

echo "== Week 2 tools (warnings only)"
command -v minikube >/dev/null && echo "  [ OK ] $(minikube version --short 2>/dev/null)" || echo "  [WARN] minikube missing (Lab 4) - see section 6"
python3 -c "import matplotlib" 2>/dev/null && echo "  [ OK ] matplotlib" || echo "  [WARN] matplotlib missing (Lab 6 plots): sudo apt install python3-matplotlib"
command -v nsenter >/dev/null && echo "  [ OK ] nsenter" || echo "  [WARN] nsenter missing (Lab 5): sudo apt install util-linux"

echo; echo "Result: $pass OK, $fail FAIL"
[ $fail -eq 0 ] && echo "You are ready for the labs." || echo "Fix the FAIL lines before Lab 1."
