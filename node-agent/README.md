# VNM Panel Node Agent

VNM Panel Node Agent is a small dependency-free HTTP service for a Linux QEMU/KVM host. It keeps a local VM inventory in SQLite and exposes authenticated APIs for node health and VM lifecycle operations.

## Install

Run on the target Debian/Ubuntu node:

```bash
curl -fsSL https://raw.githubusercontent.com/stripathi02123-tech/Vnm-panel/main/node-agent/install-node-agent.sh | sudo bash
```

The installer installs Python 3, QEMU, QEMU utilities, OVMF, cloud-image-utils, and genisoimage. It generates an API key in `/etc/vnm-panel-node/agent.env` and starts `vnm-panel-node-agent.service`.

## Configuration

```text
VNM_NODE_HOST=0.0.0.0
VNM_NODE_PORT=9090
VNM_NODE_API_KEY=<32-byte hex key>
VNM_NODE_DB=/var/lib/vnm-panel-node/vms.db
VNM_VM_ROOT=/var/lib/vnm-panel-node/vms
VNM_NODE_LOG_DIR=/var/log/vnm-panel-node
```

Keep the API port restricted to the VNM Panel controller or a private network. The agent requires the `X-VNM-Node-Key` header for all management endpoints.

## Health

Unauthenticated:

```bash
curl http://NODE_IP:9090/health
```

Authenticated:

```bash
curl -H 'X-VNM-Node-Key: YOUR_KEY' http://NODE_IP:9090/api/v1/status
```

The status response reports hostname, OS/kernel/architecture, CPU count and load, memory, VM storage, `/dev/kvm` availability, QEMU version, `cloud-localds` availability, and VM counts.

## VM API

List:

```bash
curl -H 'X-VNM-Node-Key: YOUR_KEY' http://NODE_IP:9090/api/v1/vms
```

Create a VM record and disk:

```bash
curl -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-VNM-Node-Key: YOUR_KEY' \
  -d '{"id":"vm-1","name":"Ubuntu-1","memory_mib":2048,"vcpus":2,"disk_path":"vm-1.qcow2","disk_size":"20G"}' \
  http://NODE_IP:9090/api/v1/vms
```

Start:

```bash
curl -X POST -H 'X-VNM-Node-Key: YOUR_KEY' http://NODE_IP:9090/api/v1/vms/vm-1/start
```

Stop:

```bash
curl -X POST -H 'Content-Type: application/json' -H 'X-VNM-Node-Key: YOUR_KEY' -d '{}' http://NODE_IP:9090/api/v1/vms/vm-1/stop
```

Force stop:

```bash
curl -X POST -H 'Content-Type: application/json' -H 'X-VNM-Node-Key: YOUR_KEY' -d '{"force":true}' http://NODE_IP:9090/api/v1/vms/vm-1/stop
```

Reboot:

```bash
curl -X POST -H 'Content-Type: application/json' -H 'X-VNM-Node-Key: YOUR_KEY' -d '{}' http://NODE_IP:9090/api/v1/vms/vm-1/reboot
```

Delete:

```bash
curl -X DELETE -H 'X-VNM-Node-Key: YOUR_KEY' http://NODE_IP:9090/api/v1/vms/vm-1
```

## Service

```bash
systemctl status vnm-panel-node-agent
systemctl restart vnm-panel-node-agent
journalctl -u vnm-panel-node-agent -f
```

## Design

The agent deliberately constructs QEMU arguments as an argv list rather than passing a shell command string. VM paths are restricted to `VNM_VM_ROOT`, and the API key is compared using a constant-time comparison. The agent does not expose arbitrary shell-command execution.
