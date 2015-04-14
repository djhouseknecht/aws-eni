module Aws
  class ENI
    module Meta

      # EC2 instance meta-data connection settings
      HOST = '169.254.169.254'
      PORT = '80'
      BASE = '/latest/meta-data/'

      class Non200Response < RuntimeError; end
      class ConnectionFailed < RuntimeError; end

      # These are the errors we trap when attempting to talk to the instance
      # metadata service.  Any of these imply the service is not present, no
      # responding or some other non-recoverable error.
      FAILURES = [
        Errno::EHOSTUNREACH,
        Errno::ECONNREFUSED,
        Errno::EHOSTDOWN,
        Errno::ENETUNREACH,
        SocketError,
        Timeout::Error,
        Non200Response,
      ]

      # Attempt to execute the open connection block :retries times. All other
      # options pass through to open_connection.
      def self.run(options = {}, &block)
        retries = options[:retries] || 5
        failed_attempts = 0
        begin
          open_connection(options, &block)
        rescue *FAILURES => e
          if failed_attempts < retries
            # retry after an ever increasing cooldown time with each failure
            Kernel.sleep(1.2 ** failed_attempts)
            failed_attempts += 1
            retry
          else
            raise ConnectionFailed, "Connection failed after #{retries} retries."
          end
        end
      end

      # Open a connection to the instance metadata endpoint with optional
      # settings for open and read timeouts.
      def self.open_connection(options = {})
        http = Net::HTTP.new(HOST, PORT, nil)
        http.open_timeout = options[:open_timeout] || 5
        http.read_timeout = options[:read_timeout] || 5
        http.start
        yield(http).tap { http.finish }
      end

      # Perform a GET request on an open connection to the instance metadata
      # endpoint and return the body of any 200 response.
      def self.http_get(connection, path)
        response = connection.request(Net::HTTP::Get.new(BASE + path))
        if response.code.to_i == 200
          response.body
        else
          raise Non200Response
        end
      end
    end
  end
end
