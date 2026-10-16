# k3s-bootstrap
VM bootstrapping to run k3s and Flux

## Add worker nodes

Run `setup-k3s-worker.sh` on each **new Debian/Ubuntu VM** (x86-64 or ARM64).
It installs only the K3s agent, not a server or Flux, and refuses existing
K3s installations/configuration. Root or sudo access is required.

1. On the existing server, obtain the join token with
   `sudo cat /var/lib/rancher/k3s/server/agent-token`. Treat it as a secret.
2. On the new VM, run:

   ```sh
   bash setup-k3s-worker.sh --server https://SERVER_IP:6443
   ```

   Enter the token at the hidden prompt. For unattended provisioning,
   supply `K3S_TOKEN` securely through the environment; do not put it in
   command-line arguments or shell history. `K3S_URL` can replace `--server`.
   Environment variables may be observable by privileged processes.
3. On the server, verify registration and readiness with
   `sudo k3s kubectl get nodes -o wide`.

The script installs prerequisites, disables swap (including `/etc/fstab`
entries), and stores the join token at `/etc/rancher/k3s/worker-token`
with root ownership and mode `0600`. It downloads the official K3s installer;
internet access is required. Use a K3s release compatible with your server
by setting the installer's `INSTALL_K3S_VERSION` environment variable.

Allow workers to reach the server on TCP 6443. With the default Flannel VXLAN
backend, allow UDP 8472 between cluster nodes and TCP 10250 between nodes
for kubelet metrics. Do not expose these internal ports to the internet.
The script does not change firewall rules.

If workloads use the private registry configured on the initial server,
securely provision the corresponding `/etc/rancher/k3s/registries.yaml`
on every worker with root ownership and mode `0600` before joining.
Registry credentials are node-local and are not copied automatically.
