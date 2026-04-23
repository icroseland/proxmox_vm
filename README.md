# proxmox_vm

A Puppet module providing a custom `proxmox_vm` type/provider to manage Proxmox VMs through the Proxmox API.

## Example

```puppet
include proxmox_vm

proxmox_vm { 'web-01':
  ensure           => present,
  vmid             => '200',
  node             => 'pve01',
  status           => running,
  cores            => 4,
  memory           => 8192,
  description      => 'Managed by Puppet',
  api_url          => 'https://pve.example.com:8006/api2/json',
  api_token_id     => 'root@pam!puppet',
  api_token_secret => Sensitive('supersecret'),
  verify_ssl       => true,
  provider         => api,
}
```

## Notes

- This implementation manages VM lifecycle (create/delete), basic hardware config (`cores`, `memory`) and runtime state (`running`/`stopped`).
- It expects token-based authentication.
- TLS certificate verification is enabled by default and can be disabled with `verify_ssl => false` for environments using self-signed certs.
- It does not perform VM migration between nodes or vmid renumbering.
