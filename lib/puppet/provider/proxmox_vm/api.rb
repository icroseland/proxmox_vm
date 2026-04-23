require 'json'
require 'net/http'
require 'openssl'
require 'uri'

Puppet::Type.type(:proxmox_vm).provide(:api) do
  desc 'Manage Proxmox VMs with the Proxmox API using token authentication.'

  mk_resource_methods

  def exists?
    !current_vm.nil?
  end

  def create
    fail Puppet::Error, 'node is required' if resource[:node].nil?
    fail Puppet::Error, 'vmid is required' if resource[:vmid].nil?
    return if vm_exists_anywhere?

    payload = {
      vmid: resource[:vmid],
      cores: resource[:cores],
      memory: resource[:memory],
      description: resource[:description]
    }.reject { |_k, v| v.nil? }

    post("nodes/#{resource[:node]}/qemu", payload)
    configure_status
  end

  def destroy
    return unless current_vm

    if current_status == 'running'
      post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/stop")
    end

    delete("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}")
  end

  def status
    state = current_status
    return :stopped if state.nil?

    state == 'running' ? :running : :stopped
  end

  def status=(value)
    if value.to_s == 'running'
      post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/start")
    else
      post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/stop")
    end
  end

  def cores=(value)
    put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { cores: value })
  end

  def memory=(value)
    put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { memory: value })
  end

  def description=(value)
    put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { description: value })
  end

  def node=(value)
    fail Puppet::Error, "Cannot move VM #{resource[:name]} between Proxmox nodes with this provider (requested node #{value})"
  end

  def vmid=(value)
    fail Puppet::Error, "Cannot change vmid for #{resource[:name]} after creation (requested vmid #{value})"
  end

  def current_vm
    @current_vm ||= begin
      response = get("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config")
      response['data']
    rescue Puppet::Error => e
      return nil if e.message.include?('404')

      raise
    end
  end

  def current_status
    response = get("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/current")
    response.dig('data', 'status')
  rescue Puppet::Error => e
    return nil if e.message.include?('404')

    raise
  end

  def vm_exists_anywhere?
    response = get('cluster/resources?type=vm')
    vm_found = response.fetch('data', []).any? do |vm|
      vm['vmid'].to_s == resource[:vmid].to_s
    end

    if vm_found
      Puppet.notice("Skipping VM creation for #{resource[:name]}: VMID #{resource[:vmid]} already exists in Proxmox.")
    end

    vm_found
  rescue Puppet::Error => e
    Puppet.warning("Unable to verify whether VMID #{resource[:vmid]} already exists before creation: #{e.message}")
    false
  end

  def configure_status
    desired = resource[:status]
    return if desired.nil?

    self.status = desired
  end

  def get(path)
    request(Net::HTTP::Get, path)
  end

  def post(path, payload = nil)
    request(Net::HTTP::Post, path, payload)
  end

  def put(path, payload = nil)
    request(Net::HTTP::Put, path, payload)
  end

  def delete(path)
    request(Net::HTTP::Delete, path)
  end

  def request(http_class, path, payload = nil)
    uri = URI.join(api_url_with_slash, path)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.verify_mode = verify_ssl? ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE

    req = http_class.new(uri)
    req['Authorization'] = "PVEAPIToken=#{resource[:api_token_id]}=#{resource[:api_token_secret]}"
    req['Accept'] = 'application/json'
    req['Content-Type'] = 'application/json'
    req.body = JSON.dump(payload) if payload

    response = http.request(req)

    unless response.code.to_i.between?(200, 299)
      raise Puppet::Error, "Proxmox API request failed for #{path}: #{response.code} #{response.body}"
    end

    return {} if response.body.nil? || response.body.empty?

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise Puppet::Error, "Invalid JSON response from Proxmox for #{path}: #{e.message}"
  end

  def api_url_with_slash
    url = resource[:api_url]
    fail Puppet::Error, 'api_url is required' if url.nil? || url.empty?

    url.end_with?('/') ? url : "#{url}/"
  end

  def verify_ssl?
    resource[:verify_ssl].to_s == 'true'
  end
end
