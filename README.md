# k3s-bootstrap

Bootstrap a Debian or Ubuntu VM as a single-node K3s cluster managed by Flux.
The setup script also configures containerd to authenticate to a container
registry and connects Flux to a Git repository.

## Requirements

- A Debian or Ubuntu VM using `systemd` on `x86_64` or `aarch64`
- Root access or a user with `sudo` privileges
- Network access to install packages, K3s, and Flux
- A Git repository for the Flux configuration
- Registry credentials and a read-only Azure DevOps personal access token

## Usage

Run the script from the repository:

```bash
bash setup-k3s-flux.sh \
  --git-url "https://dev.azure.com/contoso/platform/_git/edge-gitops" \
  --app-namespace myapp \
  --registry contosoedge.azurecr.io \
  --registry-user 11111111-2222-3333-4444-555555555555
```

The script prompts securely for the registry password and Azure DevOps PAT.
Alternatively, provide them through `REGISTRY_PASSWORD` and `FLUX_GIT_PAT`.
Avoid passing secrets directly on the command line.

### Options

| Option | Description |
| --- | --- |
| `--git-url URL` | Git repository URL (required) |
| `--git-branch BRANCH` | Branch Flux tracks (default: `main`) |
| `--git-path PATH` | Repository path Flux reconciles (default: `./apps`) |
| `--git-user USER` | HTTPS username used with the PAT (default: `flux`) |
| `--registry HOST` | Registry hostname, without a URL scheme (required) |
| `--registry-user USER` | Registry username (required) |
| `--test-image IMAGE` | Optional image to test pulling with K3s |
| `--app-namespace NAME` | Namespace containing the HelmRelease object |
| `--kube-user USER` | Local user to receive the kubeconfig |
| `--source-name NAME` | Flux GitRepository name (default: `flux-system`) |
| `--kustomization-name NAME` | Flux Kustomization name (default: `apps`) |
| `--configure-ufw` | Allow TCP ports 80 and 443 if UFW is active |
| `--expose-api` | Also allow TCP port 6443 when configuring UFW |
| `--verbose` | Print operational details and commands |
| `--help` | Show all usage information |

The script disables swap and installs or restarts K3s. Review the script before
running it, especially when using it on a machine with existing workloads.

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

## Packaging

The GitHub Actions workflow packages `README.md` and `setup-k3s-flux.sh` into a
gzip-compressed tar archive on pushes, pull requests, and manual runs. Download
the `k3s-bootstrap` artifact from the completed workflow run's **Artifacts**
section. The archive is named `k3s-bootstrap.tar.gz`.
