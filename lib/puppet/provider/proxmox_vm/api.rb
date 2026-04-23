require 'json'
require 'net/http'
require 'openssl'
require 'uri'
require 'cgi'

Puppet::Type.type(:proxmox_vm).provide(:api) do
  desc 'Manage Proxmox VMs with the Proxmox API using token authentication.'

  mk_resource_methods

  def exists?
    !current_vm.nil?
  end

  def create
    fail Puppet::Error, 'node is required' if resource[:node].nil? || resource[:node].to_s.empty?
    fail Puppet::Error, 'vmid is required' if resource[:vmid].nil? || resource[:vmid].to_s.empty?
    fail Puppet::Error, 'api_token_id is required' if resource[:api_token_id].nil? || resource[:api_token_id].to_s.empty?
    fail Puppet::Error, 'api_token_secret is required' if api_token_secret.to_s.empty?
    return if vm_exists_anywhere?

    payload = {
      vmid: resource[:vmid],
      name: resource[:name],
      cores: resource[:cores],
      memory: resource[:memory],
      description: resource[:description]
    }.reject { |_k, v| v.nil? }

    task = post("nodes/#{resource[:node]}/qemu", payload)
    wait_for_task(task)
    @current_vm = nil
    configure_status
  end

  def destroy
    return unless current_vm

    if current_status == 'running'
      stop_task = post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/stop")
      wait_for_task(stop_task)
    end

    delete_task = delete("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}")
    wait_for_task(delete_task)
    @current_vm = nil
  end

  def status
    state = current_status
    return :stopped if state.nil?

    state == 'running' ? :running : :stopped
  end

  def status=(value)
    task = if value.to_s == 'running'
             post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/start")
           else
             post("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/status/stop")
           end
    wait_for_task(task)
  end

  def cores=(value)
    task = put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { cores: value })
    wait_for_task(task)
    @current_vm = nil
  end

  def memory=(value)
    task = put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { memory: value })
    wait_for_task(task)
    @current_vm = nil
  end

  def description=(value)
    task = put("nodes/#{resource[:node]}/qemu/#{resource[:vmid]}/config", { description: value })
    wait_for_task(task)
    @current_vm = nil
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
    req['Authorization'] = "PVEAPIToken=#{resource[:api_token_id]}=#{api_token_secret}"
    req['Accept'] = 'application/json'

    if payload
      req['Content-Type'] = 'application/x-www-form-urlencoded'
      req.set_form_data(payload.transform_values(&:to_s))
    end

    response = http.request(req)

    unless response.code.to_i.between?(200, 299)
      raise Puppet::Error, "Proxmox API request failed for #{path}: #{response.code} #{response.body}"
    end

    return {} if response.body.nil? || response.body.empty?

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise Puppet::Error, "Invalid JSON response from Proxmox for #{path}: #{e.message}"
  end

  def wait_for_task(task_upid)
    return if task_upid.nil? || task_upid.to_s.empty?

    decoded = CGI.unescape(task_upid.to_s)
    parts = decoded.split(':')
    fail Puppet::Error, "Unexpected Proxmox task format: #{task_upid}" if parts.length < 7

    node = parts[1]
    timeout = 300
    start = Time.now

    loop do
      response = get("nodes/#{node}/tasks/#{CGI.escape(decoded)}/status")
      exit_status = response.dig('data', 'exitstatus')
      status = response.dig('data', 'status')

      return if status == 'stopped' && exit_status == 'OK'

      if status == 'stopped' && exit_status && exit_status != 'OK'
        raise Puppet::Error, "Proxmox task #{decoded} failed with exit status #{exit_status}"
      end

      if Time.now - start > timeout
        raise Puppet::Error, "Timed out waiting for Proxmox task #{decoded}"
      end

      sleep 2
    end
  end

  def api_url_with_slash
    url = resource[:api_url]
    fail Puppet::Error, 'api_url is required' if url.nil? || url.empty?

    url.end_with?('/') ? url : "#{url}/"
  end

  def api_token_secret
    secret = resource[:api_token_secret]
    return '' if secret.nil?

    secret.respond_to?(:unwrap) ? secret.unwrap : secret.to_s
  end

  def verify_ssl?
    resource[:verify_ssl].to_s == 'true'
  end
end
