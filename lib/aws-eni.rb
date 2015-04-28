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
        id:           response[:network_interface][:network_interface_id],
        subnet_id:    response[:network_interface][:subnet_id],
        api_response: response[:network_interface]
      }
    end

    # attach network interface
    def attach_interface(id, options = {})
      do_enable = true unless options[:enable] == false
      do_config = true unless options[:configure] == false
      assert_ifconfig_access if do_config || do_enable

      interface = IFconfig[options[:device_number] || options[:name]]
      raise InvalidParameterError, "Interface #{interface.name} is already in use" if interface.exists?

      params = {}
      params[:network_interface_id] = id
      params[:instance_id] = environment[:instance_id]
      params[:device_index] = interface.device_number

      response = client.attach_network_interface(params)

      if options[:block] || do_config || do_enable
        wait_for 'the interface to attach', rescue: ConnectionFailed do
          interface.exists? && interface_status(interface.interface_id) == 'in-use'
        end
      end
      interface.configure if do_config
      interface.enable if do_enable
      {
        id:           interface.interface_id,
        name:         interface.name,
        configured:   options[:configure],
        api_response: response
      }
    end

    # detach network interface
    def detach_interface(id, options = {})
      interface = IFconfig.filter(id).first
      raise InvalidParameterError, "Interface #{interface.name} does not exist" unless interface && interface.exists?
      if options[:name] && interface.name != options[:name]
        raise InvalidParameterError, "Interface #{interface.interface_id} not found on #{options[:name]}"
      end
      if options[:device_number] && interface.device_number != options[:device_number].to_i
        raise InvalidParameterError, "Interface #{interface.interface_id} not found at index #{options[:device_number]}"
      end

      description = client.describe_network_interfaces(filters: [{
        name: 'attachment.instance-id',
        values: [environment[:instance_id]]
      },{
        name: 'network-interface-id',
        values: [interface.interface_id]
      }])
      description = description[:network_interfaces].first
      raise UnknownInterfaceError, "Interface attachment could not be located" unless description

      interface.disable
      interface.deconfigure
      client.detach_network_interface(
        attachment_id: description[:attachment][:attachment_id],
        force: true
      )
      created_by_us = description.tag_set.any? { |tag| tag.key == 'created by' && tag.value == owner_tag }
      do_delete = options[:delete] || options[:delete].nil? && created_by_us

      if options[:block] || do_delete
        wait_for 'the interface to detach', interval: 0.3 do
          !interface.exists? && interface_status(description[:network_interface_id]) == 'available'
        end
      end
      client.delete_network_interface(network_interface_id: description[:network_interface_id]) if do_delete
      {
        id:            description[:network_interface_id],
        name:          "eth#{description[:attachment][:device_index]}",
        device_number: description[:attachment][:device_index],
        created_by_us: created_by_us,
        deleted:       do_delete,
        api_response:  description
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
        skip = safe_mode && interface.tag_set.any? do |tag|
          begin
            tag.key == 'created on' && Time.now - Time.parse(tag.value) < 60
          rescue ArgumentError
            false
          end
        end
        unless skip
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
    def assign_secondary_ip(interface, options = {})
      raise NoMethodError, "assign_secondary_ip not yet implemented"
      {
        private_ip:   '0.0.0.0',
        device_name:  'eth0',
        interface_id: 'eni-1a2b3c4d'
      }
    end

    # remove a private ip using the AWS api and remove it from local config
    def unassign_secondary_ip(private_ip, options = {})
      raise NoMethodError, "unassign_secondary_ip not yet implemented"
      {
        private_ip:     '0.0.0.0',
        device_name:    'eth0',
        interface_id:   'eni-1a2b3c4d',
        public_ip:      '0.0.0.0',
        allocation_id:  'eipalloc-1a2b3c4d',
        association_id: 'eipassoc-1a2b3c4d',
        released:       true
      }
    end

    # associate a private ip with an elastic ip through the AWS api
    def associate_elastic_ip(private_ip, options = {})
      raise NoMethodError, "associate_elastic_ip not yet implemented"
      {
        private_ip:     '0.0.0.0',
        device_name:    'eth0',
        interface_id:   'eni-1a2b3c4d',
        public_ip:      '0.0.0.0',
        allocation_id:  'eipalloc-1a2b3c4d',
        association_id: 'eipassoc-1a2b3c4d'
      }
    end

    # dissociate a public ip from a private ip through the AWS api and
    # optionally release the public ip
    def dissociate_elastic_ip(ip, options = {})
      raise NoMethodError, "dissociate_elastic_ip not yet implemented"
      {
        private_ip:     '0.0.0.0',
        device_name:    'eth0',
        interface_id:   'eni-1a2b3c4d',
        public_ip:      '0.0.0.0',
        allocation_id:  'eipalloc-1a2b3c4d',
        association_id: 'eipassoc-1a2b3c4d',
        released:       true
      }
    end

    # allocate a new elastic ip address
    def allocate_elastic_ip
      raise NoMethodError, "allocate_elastic_ip not yet implemented"
      {
        public_ip:     '0.0.0.0',
        allocation_id: 'eipalloc-1a2b3c4d'
      }
    end

    # release the specified elastic ip address
    def release_elastic_ip(ip, options = {})
      raise NoMethodError, "release_elastic_ip not yet implemented"
      {
        public_ip:     '0.0.0.0',
        allocation_id: 'eipalloc-1a2b3c4d'
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
        }
      }
      test_methods.each do |method, params|
        begin
          params ||= {}
          params[:dry_run] = true
          client.public_send(method, params)
          raise Error, "Unexpected behavior while testing AWS API access"
        rescue Aws::EC2::Errors::DryRunOperation
          # success
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
