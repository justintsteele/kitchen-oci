# frozen_string_literal: true

# Author:: Justin Steele (<justin.steele@oracle.com>)
#
# Copyright (C) 2024, Stephen Pearson
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Kitchen
  module Driver
    class Oci
      module Models
        # dbaas model
        class Dbaas < Instance # rubocop:disable Metrics/ClassLength
          def initialize(config, state, oci, api, action)
            super
            @launch_details = OCI::Database::Models::LaunchDbSystemDetails.new
            @database_details = OCI::Database::Models::CreateDatabaseDetails.new
            @db_home_details = OCI::Database::Models::CreateDbHomeDetails.new
            @instance_details = COMMON_DETAILS + INSTANCE_DETAILS
          end

          #
          # TODO: add support for the #domain property
          #       add support for #database_software_image_id property
          #
          # Items in this array should correspond to private methods in this class that set attributes in @launch_details
          #
          INSTANCE_DETAILS = %i{
            hostname
            display_name
            cluster_name
            cpu_core_count
            db_home
            database_edition
            subnet_id
            nsg_ids
            pubkey
            initial_data_storage_size_in_gb
            node_count
            license_model
          }.freeze

          #
          # The details model that describes the db system
          #
          # @return [OCI::Database::Models::LaunchDbSystemDetails]
          #
          attr_accessor :launch_details

          #
          # The details model that describes the database
          #
          # @return [OCI::Database::Models::CreateDatabaseDetails]
          #
          attr_accessor :database_details

          #
          # The details model that describes the database home
          #
          # @return [OCI::Database::Models::CreateDbHomeDetails]
          #
          attr_accessor :db_home_details

          #
          # An array of symbols indicating the various getter and setter methods required to build the launch_details
          #
          # @return [Array]
          #
          attr_reader   :instance_details

          def launch
            response = api.dbaas.launch_db_system(launch_instance_details)
            instance_id = response.data.id

            api.dbaas.get_db_system(instance_id).wait_until(:lifecycle_state, OCI::Database::Models::DbSystem::LIFECYCLE_STATE_AVAILABLE,
                                                            max_interval_seconds: 900, max_wait_seconds: 21_600)
            final_state(state, instance_id)
          end

          def terminate
            api.dbaas.terminate_db_system(state[:server_id])
            api.dbaas.get_db_system(state[:server_id]).wait_until(:lifecycle_state, OCI::Database::Models::DbSystem::LIFECYCLE_STATE_TERMINATING,
                                                                  max_interval_seconds: 900, max_wait_seconds: 21_600)
          end

          private

          def db_home
            db_version
            db_home_display_name
            db_home_details.database = create_database_details
            launch_details.db_home = db_home_details
          end

          def create_database_details
            db_name
            pdb_name
            admin_password
            character_set
            db_workload
            ncharacter_set
            db_backup_config
          end

          def subnet_id
            launch_details.subnet_id = config[:subnet_id]
          end

          def nsg_ids
            launch_details.nsg_ids = config[:nsg_ids]
          end

          def hostname
            # The hostname must begin with an alphabetic character, and can contain alphanumeric characters and hyphens (-).
            # The maximum length of the hostname is 16 characters
            long_name = [hostname_prefix, long_hostname_suffix].compact.join("-")
            trimmed_name = [hostname_prefix[0, 12], random_string(3)].compact.join("-")
            launch_details.hostname = [long_name, trimmed_name].min { |l, t| l.size <=> t.size }
          end

          def display_name
            # The user-friendly name for the DB system. The name does not have to be unique.
            launch_details.display_name = [config[:hostname_prefix], random_string(4), random_number(2)].compact.join("-")
          end

          def hostname_prefix
            config[:hostname_prefix]
          end

          def node_count
            launch_details.node_count = 1
          end

          def long_hostname_suffix
            [random_string(25 - hostname_prefix.length), random_string(3)].compact.join("-")
          end

          def pubkey
            result = []
            result << File.readlines(config[:ssh_keypath]).first.chomp
            launch_details.ssh_public_keys = result
          end

          def cpu_core_count
            launch_details.cpu_core_count = config[:dbaas][:cpu_core_count] ||= 2
          end

          def license_model
            license = config[:dbaas][:license_model] ||= OCI::Database::Models::DbSystem::LICENSE_MODEL_BRING_YOUR_OWN_LICENSE
            launch_details.license_model = license
          end

          def initial_data_storage_size_in_gb
            launch_details.initial_data_storage_size_in_gb = config[:dbaas][:initial_data_storage_size_in_gb] ||= 256
          end

          def dbaas_node(instance_id)
            api.dbaas.list_db_nodes(oci.compartment, db_system_id: instance_id).data
          end

          def instance_ip(instance_id)
            vnic = dbaas_node(instance_id).select(&:vnic_id).first.vnic_id
            if public_ip_allowed?
              api.network.get_vnic(vnic).data.public_ip
            else
              api.network.get_vnic(vnic).data.private_ip
            end
          end

          def db_version
            raise "db_version cannot be nil!" if config[:dbaas][:db_version].nil?

            db_home_details.db_version = config[:dbaas][:db_version]
          end

          def db_home_display_name
            db_home_details.display_name = ["dbhome", random_number(10)].compact.join
          end

          def character_set
            database_details.character_set = config[:dbaas][:character_set] ||= "AL32UTF8"
          end

          def ncharacter_set
            database_details.ncharacter_set = config[:dbaas][:ncharacter_set] ||= "AL16UTF16"
          end

          def db_workload
            workload = config[:dbaas][:db_workload] ||= OCI::Database::Models::CreateDatabaseDetails::DB_WORKLOAD_OLTP
            database_details.db_workload = workload
          end

          def admin_password
            database_details.admin_password = config[:dbaas][:admin_password] ||= random_password(%w{# _ -})
          end

          def db_name
            database_details.db_name = config[:dbaas][:db_name] ||= "dbaas1"
          end

          def pdb_name
            database_details.pdb_name = config[:dbaas][:pdb_name] ||= "pdb001"
          end

          def db_backup_config
            database_details.db_backup_config = OCI::Database::Models::DbBackupConfig.new.tap do |l|
              l.auto_backup_enabled = false
            end
            database_details
          end

          def database_edition
            db_edition = config[:dbaas][:database_edition] ||= OCI::Database::Models::DbSystem::DATABASE_EDITION_ENTERPRISE_EDITION
            launch_details.database_edition = db_edition
          end

          def cluster_name
            prefix = config[:hostname_prefix].split("-")[0]
            # 11 character limit for cluster_name in DBaaS
            cn = if prefix.length >= 11
                   prefix[0, 11]
                 else
                   [prefix, random_string(10 - prefix.length)].compact.join("-")
                 end
            launch_details.cluster_name = cn
          end
        end
      end
    end
  end
end
