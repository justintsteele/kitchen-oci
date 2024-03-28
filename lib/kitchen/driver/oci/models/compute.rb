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
        # Compute instance model
        class Compute < Instance # rubocop:disable Metrics/ClassLength
          def initialize(config, state, oci, api, action)
            super
            @launch_details = OCI::Core::Models::LaunchInstanceDetails.new
            @instance_details = COMMON_DETAILS + INSTANCE_DETAILS
          end

          INSTANCE_DETAILS = %i{
            hostname_display_name
            instance_source_details
            instance_metadata
            preemptible_instance_config
            shape_config
          }.freeze

          #
          # The details model that describes a compute instance
          #
          # @return [OCI::Core::Models::LaunchInstanceDetails]
          #
          attr_accessor :launch_details

          #
          # An array of symbols indicating the various getter and setter methods required to build the launch_details
          #
          # @return [Array]
          #
          attr_reader   :instance_details

          def launch
            process_windows_options
            response = api.compute.launch_instance(launch_instance_details)
            instance_id = response.data.id
            api.compute.get_instance(instance_id).wait_until(:lifecycle_state, OCI::Core::Models::Instance::LIFECYCLE_STATE_RUNNING )
            final_state(state, instance_id)
          end

          def terminate
            api.compute.terminate_instance(state[:server_id])
            api.compute.get_instance(state[:server_id]).wait_until(:lifecycle_state, OCI::Core::Models::Instance::LIFECYCLE_STATE_TERMINATING)
          end

          private

          def hostname_display_name
            display_name = hostname
            launch_details.display_name = display_name
            launch_details.create_vnic_details = create_vnic_details(display_name)
          end

          def hostname
            [config[:hostname_prefix], random_string(6)].compact.join("-")
          end

          def preemptible_instance_config
            return unless config[:preemptible_instance]

            launch_details.preemptible_instance_config = OCI::Core::Models::PreemptibleInstanceConfigDetails.new(
              preemption_action:
                OCI::Core::Models::TerminatePreemptionAction.new(
                  type: "TERMINATE", preserve_boot_volume: true
                )
            )
          end

          def shape_config
            return if config[:shape_config].empty?

            launch_details.shape_config = OCI::Core::Models::LaunchInstanceShapeConfigDetails.new(
              ocpus: config[:shape_config][:ocpus],
              memory_in_gbs: config[:shape_config][:memory_in_gbs],
              baseline_ocpu_utilization: config[:shape_config][:baseline_ocpu_utilization] || "BASELINE_1_1"
            )
          end

          def instance_source_details
            launch_details.source_details = OCI::Core::Models::InstanceSourceViaImageDetails.new(
              sourceType: "image",
              imageId: config[:image_id],
              bootVolumeSizeInGBs: config[:boot_volume_size_in_gbs]
            )
          end

          def create_vnic_details(name)
            OCI::Core::Models::CreateVnicDetails.new(
              assign_public_ip: public_ip_allowed?,
              display_name: name,
              hostname_label: name,
              nsg_ids: config[:nsg_ids],
              subnetId: config[:subnet_id]
            )
          end

          def pubkey
            File.readlines(config[:ssh_keypath]).first.chomp
          end

          def instance_metadata
            launch_details.metadata = metadata
          end

          def metadata
            md = {}
            inject_powershell
            config[:custom_metadata]&.each { |k, v| md.store(k, v) }
            md.store("ssh_authorized_keys", pubkey)
            md.store("user_data", user_data) if config[:user_data] && !config[:user_data].empty?
            md
          end

          def vnics(instance_id)
            vnic_attachments(instance_id).map { |att| api.network.get_vnic(att.vnic_id).data }
          end

          def vnic_attachments(instance_id)
            att = api.compute.list_vnic_attachments(oci.compartment, instance_id: instance_id).data
            raise "Could not find any VNIC attachments" unless att.any?

            att
          end

          def instance_ip(instance_id)
            vnic = vnics(instance_id).select(&:is_primary).first
            if public_ip_allowed?
              config[:use_private_ip] ? vnic.private_ip : vnic.public_ip
            else
              vnic.private_ip
            end
          end

          def process_windows_options
            return unless windows_state?

            state.store(:username, config[:winrm_user])
            state.store(:password, config[:winrm_password] || random_password(%w{@ - ( ) .}))
          end

          def windows_state?
            config[:setup_winrm] && config[:password].nil? && state[:password].nil?
          end

          def winrm_ps1
            filename = File.join(__dir__, %w{.. .. .. .. .. tpl setup_winrm.ps1.erb})
            tpl = ERB.new(File.read(filename))
            tpl.result(binding)
          end

          def inject_powershell
            return unless config[:setup_winrm]

            data = winrm_ps1
            config[:user_data] ||= []
            config[:user_data] << {
              type: "x-shellscript",
              inline: data,
              filename: "setup_winrm.ps1",
            }
          end
        end
      end
    end
  end
end
