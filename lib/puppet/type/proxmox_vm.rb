Puppet::Type.newtype(:proxmox_vm) do
  @doc = 'Manage Proxmox virtual machines through the Proxmox REST API.'

  ensurable

  newparam(:name, namevar: true) do
    desc 'Logical name of the VM resource in Puppet.'
  end

  newproperty(:vmid) do
    desc 'Unique numeric VM identifier in Proxmox.'
    munge(&:to_s)
    validate do |value|
      raise ArgumentError, 'vmid must be numeric' unless value.to_s.match?(/^\d+$/)
    end
  end

  newproperty(:node) do
    desc 'Name of the Proxmox node where the VM exists.'
  end

  newproperty(:status) do
    desc 'Desired runtime status for the VM.'
    newvalues(:running, :stopped)
  end

  newproperty(:cores) do
    desc 'Number of vCPUs to configure.'
    munge(&:to_i)
    validate do |value|
      raise ArgumentError, 'cores must be a positive integer' unless value.to_i.positive?
    end
  end

  newproperty(:memory) do
    desc 'Amount of memory in MiB.'
    munge(&:to_i)
    validate do |value|
      raise ArgumentError, 'memory must be a positive integer' unless value.to_i.positive?
    end
  end

  newproperty(:description) do
    desc 'Free-form VM description in Proxmox.'
  end

  newparam(:api_url) do
    desc 'Base Proxmox API URL, for example https://pve.example.com:8006/api2/json.'
  end

  newparam(:api_token_id) do
    desc 'Proxmox API token identifier, for example root@pam!puppet.'
  end

  newparam(:api_token_secret) do
    desc 'Proxmox API token secret.'
    sensitive true
  end

  newparam(:verify_ssl) do
    desc 'Whether to verify the Proxmox API TLS certificate. Defaults to true.'
    newvalues(:true, :false, true, false)
    defaultto :true
    munge do |value|
      value.to_s == 'true' ? :true : :false
    end
  end

  autorequire(:class) do
    ['proxmox_vm']
  end
end
