require 'time'
require 'aws-sdk'
require 'aws-eni/version'
require 'aws-eni/errors'
require 'aws-eni/meta'
require 'aws-eni/ifconfig'

module Aws
  module ENI
    extend self

    def environment
      @environment ||= {}.tap do |e|
        hwaddr = IFconfig['eth0'].hwaddr
        Meta.open_connection do |conn|
          e[:instance_id] = Meta.http_get(conn, 'instance-id')
          e[:availability_zone] = Meta.http_get(conn, 'placement/availability-zone')
          e[:region] = e[:availability_zone].sub(/(.*)[a-z]/,'\1')
          e[:vpc_id] = Meta.http_get(conn, "network/interfaces/macs/#{hwaddr}/vpc-id")
          e[:vpc_cidr] = Meta.http_get(conn, "network/interfaces/macs/#{hwaddr}/vpc-ipv4-cidr-block")
        end
        unless e[:vpc_id]
          raise EnvironmentError, "Unable to detect VPC settings, library incompatible with EC2-Classic"
        end
      end.freeze
    rescue ConnectionFailed
      raise EnvironmentError, "Unable to load EC2 meta-data"
    end

    def owner_tag(new_owner = nil)
      @owner_tag = new_owner.to_s if new_owner
      @owner_tag ||= 'aws-eni script'
    end

    def timeout(new_default = nil)
      @timeout = new_default.to_i if new_default
      @timeout ||= 30
    end

    def client
      @client ||= Aws::EC2::Client.new(region: environment[:region])
    end

    # return our internal model of this instance's network configuration on AWS
    def list(filter = nil)
      IFconfig.filter(filter).map(&:to_h) if environment
    end

    # sync local machine's network interface config with the EC2 meta-data
    # pass dry_run option to check whether configuration is out of sync without
    # modifying it
    def configure(filter = nil, options = {})
      IFconfig.configure(filter, options) if environment
    end

    # clear local machine's network interface config
    def deconfigure(filter = nil)
      IFconfig.deconfigure(filter) if environment
    end

    # create network interface
    def create_interface(options = {})
      timestamp = Time.now.xmlschema
      params = {}
      params[:subnet_id] = options[:subnet_id] || IFconfig.first.subnet_id
      params[:private_ip_address] = options[:primary_ip] if options[:primary_ip]
      params[:groups] = [*options[:security_groups]] if options[:security_groups]
      params[:description] = "generated by #{owner_tag} from #{environment[:instance_id]} on #{timestamp}"

      response = client.create_network_interface(params)
      wait_for 'the interface to be created', rescue: Aws::EC2::Errors::ServiceError do
        if interface_status(response[:network_interface][:network_interface_id]) == 'available'
          client.create_tags(resources: [response[:network_interface][:network_interface_id]], tags: [
            { key: 'created by',   value: owner_tag },
            { key: 'created on',   value: timestamp },
            { key: 'created from', value: environment[:instance_id] }
          ])
        end
      end
      {
        interface_id: response[:network_interface][:network_interface_id],
        subnet_id:    response[:network_interface][:subnet_id],
        api_response: response[:network_interface]
      }
    end

    # attach network interface
    def attach_interface(id, options = {})
      do_enable = true unless options[:enable] == false
      do_config = true unless options[:configure] == false
      assert_ifconfig_access if do_config || do_enable

      device = IFconfig[options[:device_number] || options[:name]].assert(exists: false)

      response = client.attach_network_interface(
        network_interface_id: id,
        instance_id: environment[:instance_id],
        device_index: device.device_number
      )

      if options[:block] || do_config || do_enable
        wait_for 'the interface to attach', rescue: ConnectionFailed do
          device.exists? && interface_status(device.interface_id) == 'in-use'
        end
      end
      device.configure if do_config
      device.enable if do_enable
      {
        interface_id:  device.interface_id,
        device_name:   device.name,
        device_number: device.device_number,
        enabled:       do_enable,
        configured:    do_config,
        api_response:  response
      }
    end

    # detach network interface
    def detach_interface(id, options = {})
      device = IFconfig[id].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      interface_id = device.interface_id

      response = client.describe_network_interfaces(filters: [{
        name: 'attachment.instance-id',
        values: [environment[:instance_id]]
      },{
        name: 'network-interface-id',
        values: [interface_id]
      }])
      interface = response[:network_interfaces].first
      raise UnknownInterfaceError, "Interface attachment could not be located" unless interface

      device.disable
      device.deconfigure
      client.detach_network_interface(
        attachment_id: interface[:attachment][:attachment_id],
        force: true
      )
      created_by_us = interface.tag_set.any? { |tag| tag.key == 'created by' && tag.value == owner_tag }
      do_delete = options[:delete] || options[:delete].nil? && created_by_us

      if options[:block] || do_delete
        wait_for 'the interface to detach', interval: 0.3 do
          !device.exists? && interface_status(interface[:network_interface_id]) == 'available'
        end
      end
      client.delete_network_interface(network_interface_id: interface[:network_interface_id]) if do_delete
      {
        interface_id:  interface_id,
        device_name:   device.name,
        device_number: device.device_number,
        created_by_us: created_by_us,
        deleted:       do_delete,
        api_response:  interface
      }
    end

    # delete unattached network interfaces
    def clean_interfaces(filter = nil, options = {})
      safe_mode = true unless options[:safe_mode] == false

      filters = [
        { name: 'vpc-id', values: [environment[:vpc_id]] },
        { name: 'status', values: ['available'] }
      ]
      if filter
        case filter
        when /^eni-/
          filters << { name: 'network-interface-id', values: [filter] }
        when /^subnet-/
          filters << { name: 'subnet-id', values: [filter] }
        when /^#{environment[:region]}[a-z]$/
          filters << { name: 'availability-zone', values: [filter] }
        else
          raise InvalidParameterError, "Unknown resource filter: #{filter}"
        end
      end
      if safe_mode
        filters << { name: 'tag:created by', values: [owner_tag] }
      end

      descriptions = client.describe_network_interfaces(filters: filters)
      interfaces = descriptions[:network_interfaces].select do |interface|
        unless safe_mode && interface.tag_set.any? do |tag|
          begin
            tag.key == 'created on' && Time.now - Time.parse(tag.value) < 60
          rescue ArgumentError
            false
          end
        end
          client.delete_network_interface(network_interface_id: interface[:network_interface_id])
          true
        end
      end
      {
        count:        interfaces.count,
        deleted:      interfaces.map { |eni| eni[:network_interface_id] },
        api_response: interfaces
      }
    end

    # add new private ip using the AWS api and add it to our local ip config
    def assign_secondary_ip(id, options = {})
      device = IFconfig[id].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      interface_id = device.interface_id
      current_ips = interface_ips(interface_id)
      new_ip = options[:private_ip]

      if new_ip = options[:private_ip]
        if current_ips.include?(new_ip)
          raise InvalidParameterError, "IP #{new_ip} already assigned to #{device.name}"
        end
        client.assign_private_ip_addresses(
          network_interface_id: interface_id,
          private_ip_addresses: [new_ip],
          allow_reassignment: false
        )
        wait_for 'private ip address to be assigned' do
          interface_ips(interface_id).include?(new_ip)
        end
      else
        client.assign_private_ip_addresses(
          network_interface_id: interface_id,
          secondary_private_ip_address_count: 1,
          allow_reassignment: false
        )
        wait_for 'new private ip address to be assigned' do
          new_ips = interface_ips(interface_id) - current_ips
          new_ip = new_ips.first if new_ips
        end
      end

      unless options[:configure] == false
        device.add_alias(new_ip)
        if options[:block] && !IFconfig.test(new_ip, target: device.gateway)
          raise TimeoutError, "Timed out waiting for ip address to become active"
        end
      end
      {
        private_ip:    new_ip,
        interface_id:  interface_id,
        device_name:   device.name,
        device_number: device.device_number,
        interface_ips: current_ips << new_ip
      }
    end

    # remove a private ip using the AWS api and remove it from local config
    def unassign_secondary_ip(private_ip, options = {})
      do_release = !!options[:release]

      find = options[:device_name] || options[:device_number] || options[:interface_id] || private_ip
      device = IFconfig[find].assert(
        exists: true,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )

      resp = client.describe_network_interfaces(network_interface_ids: [device.interface_id])
      interface = resp[:network_interfaces].first
      raise UnknownInterfaceError, "Interface attachment could not be located" unless interface

      unless addr_info = interface[:private_ip_addresses].find { |addr| addr[:private_ip_address] == private_ip }
        raise InvalidParameterError, "IP #{private_ip} not found on #{device.name}"
      end
      if addr_info[:primary]
        raise InvalidParameterError, "The primary IP address of an interface cannot be unassigned"
      end

      if assoc = addr_info[:association]
        client.release_address(allocation_id: assoc[:allocation_id]) if do_release
      end

      device.remove_alias(private_ip)
      client.unassign_private_ip_addresses(
        network_interface_id: interface[:network_interface_id],
        private_ip_addresses: [private_ip]
      )
      {
        private_ip:     private_ip,
        device_name:    device.name,
        interface_id:   device.interface_id,
        public_ip:      assoc && assoc[:public_ip],
        allocation_id:  assoc && assoc[:allocation_id],
        association_id: assoc && assoc[:association_id],
        released:       assoc && do_release
      }
    end

    # associate a private ip with an elastic ip through the AWS api
    def associate_elastic_ip(private_ip, options = {})
      find = options[:device_name] || options[:device_number] || options[:interface_id] || private_ip
      device = IFconfig[find].assert(
        exists: true,
        private_ip:    private_ip,
        device_name:   options[:device_name],
        interface_id:  options[:interface_id],
        device_number: options[:device_number]
      )
      options[:public_ip] ||= options[:allocation_id]

      if public_ip = device.public_ips[private_ip]
        raise InvalidParameterError, "IP #{private_ip} already has an associated EIP (#{public_ip})"
      end

      if options[:public_ip]
        eip = describe_address(options[:public_ip])
        if options[:allocation_id] && eip[:allocation_id] != options[:allocation_id]
          raise InvalidParameterError, "EIP #{eip[:public_ip]} (#{eip[:allocation_id]}) does not match #{options[:allocation_id]}"
        end
      else
        eip = allocate_elastic_ip
      end

      resp = client.associate_address(
        network_interface_id: device.interface_id,
        allocation_id:        eip[:allocation_id],
        private_ip_address:   private_ip,
        allow_reassociation:  false
      )

      if options[:block] && !IFconfig.test(private_ip)
        raise TimeoutError, "Timed out waiting for ip address to become active"
      end
      {
        private_ip:     private_ip,
        device_name:    device.name,
        interface_id:   device.interface_id,
        public_ip:      eip[:public_ip],
        allocation_id:  eip[:allocation_id],
        association_id: resp[:association_id]
      }
    end

    # dissociate a public ip from a private ip through the AWS api and
    # optionally release the public ip
    def dissociate_elastic_ip(ip, options = {})
      do_release = !!options[:release]
      eip = describe_address(ip)

      if find = options[:device_name] || options[:device_number] || options[:interface_id]
        device = IFconfig[find].assert(
          device_name:   options[:device_name],
          device_number: options[:device_number],
          interface_id:  options[:interface_id]
        )
        if device.interface_id != eip[:network_interface_id]
          raise UnknownInterfaceError, "EIP #{public_ip} is not associated with interface #{device.name} (#{device.interface_id})"
        end
      else
        begin
          device = IFconfig[eip[:network_interface_id]]
        rescue UnknownInterfaceError
          raise UnknownInterfaceError, "EIP #{public_ip} is not associated with an interface on this machine"
        end
      end

      client.disassociate_address(association_id: eip[:association_id])
      client.release_address(allocation_id: eip[:allocation_id]) if do_release
      {
        private_ip:     eip[:private_ip_address],
        device_name:    device.name,
        interface_id:   eip[:network_interface_id],
        public_ip:      eip[:public_ip],
        allocation_id:  eip[:allocation_id],
        association_id: eip[:association_id],
        released:       do_release
      }
    end

    # allocate a new elastic ip address
    def allocate_elastic_ip
      eip = client.allocate_address(domain: 'vpc')
      {
        public_ip:     eip[:public_ip],
        allocation_id: eip[:allocation_id]
      }
    end

    # release the specified elastic ip address
    def release_elastic_ip(ip)
      eip = describe_address(ip)
      if eip[:association_id]
        raise AWSPermissionError, "Elastic IP #{eip[:public_ip]} (#{eip[:allocation_id]}) is currently in use"
      end
      client.release_address(allocation_id: eip[:allocation_id])
      {
        public_ip:     eip[:public_ip],
        allocation_id: eip[:allocation_id]
      }
    end

    # test whether we have permission to modify our local configuration
    def can_modify_ifconfig?
      IFconfig.mutable?
    end

    def assert_ifconfig_access
      raise PermissionError, 'Insufficient user priveleges (try sudo)' unless can_modify_ifconfig?
    end

    # test whether we have the appropriate permissions within our AWS access
    # credentials to perform all possible API calls
    def can_access_ec2?
      client = self.client
      test_methods = {
        describe_network_interfaces: nil,
        create_network_interface: {
          subnet_id: 'subnet-abcd1234'
        },
        attach_network_interface: {
          network_interface_id: 'eni-abcd1234',
          instance_id: 'i-abcd1234',
          device_index: 0
        },
        detach_network_interface: {
          attachment_id: 'eni-attach-abcd1234'
        },
        delete_network_interface: {
          network_interface_id: 'eni-abcd1234'
        },
        create_tags: {
          resources: ['eni-abcd1234'],
          tags: []
        },
        describe_addresses: nil,
        allocate_address: nil,
        release_address: {
          dry_run: true,
          allocation_id: 'eipalloc-no_exist'
        },
        associate_address: {
          allocation_id: 'eipalloc-no_exist',
          network_interface_id: 'eni-abcd1234'
        }
        # has no dry_run method
        # assign_private_ip_addresses: {
        #   network_interface_id: 'eni-abcd1234'
        # }
      }
      test_methods.each do |method, params|
        begin
          params ||= {}
          params[:dry_run] = true
          client.public_send(method, params)
          raise Error, "Unexpected behavior while testing AWS API access"
        rescue Aws::EC2::Errors::DryRunOperation
          # success
        rescue Aws::EC2::Errors::InvalidAllocationIDNotFound
          # release_address does not properly support dry_run
        rescue Aws::EC2::Errors::UnauthorizedOperation
          return false
        end
      end
      true
    end

    def assert_ec2_access
      raise AWSPermissionError, 'Insufficient AWS API access' unless can_access_ec2?
    end

    private

    # use either an ip address or allocation id
    def describe_address(address)
      filter_by = case address
        when /^eipalloc-/
          'allocation-id'
        when /^eipassoc-/
          'association-id'
        else
          if IPAddr.new(environment[:vpc_cidr]) === IPAddr.new(address)
            'private-ip-address'
          else
            'public-ip'
          end
        end
      resp = client.describe_addresses(filters: [
        { name: 'domain', values: ['vpc'] },
        { name: filter_by, values: [address] }
      ])
      raise InvalidParameterError, "IP #{address} could not be located" if resp[:addresses].empty?
      resp[:addresses].first
    end

    def interface_ips(id)
      resp = client.describe_network_interfaces(network_interface_ids: [id])
      interface = resp[:network_interfaces].first
      if interface && interface[:private_ip_addresses]
        primary = interface[:private_ip_addresses].find { |ip| ip[:primary] }
        interface[:private_ip_addresses].map { |ip| ip[:private_ip_address] }.tap do |ips|
          # ensure primary ip is first in the list
          ips.unshift(*ips.delete(primary[:private_ip_address])) if primary
        end
      end
    end

    def interface_status(id)
      resp = client.describe_network_interfaces(network_interface_ids: [id])
      resp[:network_interfaces].first[:status] unless resp[:network_interfaces].empty?
    end

    def wait_for(task, options = {}, &block)
      errors = [*options[:rescue]]
      timeout = options[:timeout] || self.timeout
      interval = options[:interval] || 0.1

      until timeout < 0
        begin
          break if block.call
        rescue Exception => e
          raise unless errors.any? { |error| error === e }
        end
        sleep interval
        timeout -= interval
      end
      raise TimeoutError, "Timed out waiting for #{task}" unless timeout > 0
    end
  end
end
