# frozen_string_literal: true

module Nokizaru
  class Workspace
    # Port-specific ingestion and serialization helpers
    module DBPortRecords
      private

      def ingest_open_ports(artifacts, ip_obj)
        return unless ip_obj

        Array(artifacts['open_ports']).each do |port|
          number = parse_integer(port)
          import_open_port(ip_obj, number) if number
        end
      end

      def parse_integer(value)
        Integer(value)
      rescue StandardError
        nil
      end

      def serialize_open_port(open_port)
        number = open_port.respond_to?(:number) ? open_port.number : nil
        return nil unless number

        ip = open_port_ip_address(open_port)
        return number.to_i.to_s if ip.nil? || ip.empty?

        "#{ip}:#{number.to_i}"
      end

      def open_port_ip_address(open_port)
        ip_obj = open_port.respond_to?(:ip_address) ? open_port.ip_address : nil
        return nil unless ip_obj.respond_to?(:address)

        ip_obj.address.to_s
      rescue StandardError
        nil
      end

      def import_open_port(ip_obj, port_num)
        return unless defined?(Ronin::DB::Port) && defined?(Ronin::DB::OpenPort)

        port = if Ronin::DB::Port.respond_to?(:find_or_import)
                 Ronin::DB::Port.find_or_import(:tcp, port_num)
               else
                 Ronin::DB::Port.find_or_create_by(protocol: 'tcp', number: port_num)
               end
        Ronin::DB::OpenPort.find_or_create_by(ip_address: ip_obj, port: port)
      end
    end
  end
end
