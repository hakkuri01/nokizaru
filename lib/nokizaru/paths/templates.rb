# frozen_string_literal: true

module Nokizaru
  # Template resolution helpers for shipped config and metadata files
  module Paths
    def self.default_config_template
      find_template(['conf/config.json', 'metadata/config.json'])
    end

    def self.default_keys_template
      find_template(['conf/keys.json', 'metadata/keys.json'])
    end

    def self.default_metadata_template
      find_template(['data/metadata.json', 'metadata/metadata.json'])
    end

    def self.default_whois_servers_template
      find_template([
                      'data/whois_servers.json', 'data/whois-servers.json',
                      'metadata/whois_servers.json', 'metadata/whois-servers.json'
                    ])
    end

    def self.find_template(relative_paths)
      relative_paths.map { |path| File.join(project_root, path) }.find { |path| File.exist?(path) }
    end

    private_class_method :find_template
  end
end
