# frozen_string_literal: true

#
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
    module Mixins
      # Supporting mixins for common tasks
      module Support
        def random_password(special_chars)
          (Array.new(5) { special_chars.sample } +
            Array.new(5) { ('a'..'z').to_a.sample } +
            Array.new(5) { ('A'..'Z').to_a.sample } +
            Array.new(5) { ('0'..'9').to_a.sample }).shuffle.join
        end

        def random_string(length)
          Array.new(length) { ('a'..'z').to_a.sample }.join
        end

        def random_number(length)
          Array.new(length) { ('0'..'9').to_a.sample }.join
        end

        def final_state(state, instance_id)
          state.store(:server_id, instance_id)
          state.store(:hostname, instance_ip(instance_id))
          state
        end

        def process_freeform_tags(freeform_tags)
          prov = instance.provisioner.instance_variable_get(:@config)
          tags = %w[run_list policyfile]
          tags.each do |tag|
            freeform_tags[tag] = prov[tag.to_sym].join(',') unless prov[tag.to_sym].nil? || prov[tag.to_sym].empty?
          end
          freeform_tags[:kitchen] = true
          freeform_tags
        end

        def user_data
          case config[:user_data]
          when Array
            multi_part_user_data
            Base64.encode64(gzip.close.string).delete("\n")
          when String
            Base64.encode64(config[:user_data]).delete("\n")
          end
        end

        private

        def multi_part_user_data
          boundary = "MIMEBOUNDARY_#{random_string(20)}"
          msg = ["Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
                 'MIME-Version: 1.0', '']
          msg += mime_parts(boundary)
          txt = "#{msg.join("\n")}\n"
          gzip = Zlib::GzipWriter.new(StringIO.new)
          gzip << txt
        end

        def mime_parts(boundary)
          msg = []
          config[:user_data].each do |m|
            msg << "--#{boundary}"
            msg << "Content-Disposition: attachment; filename=\"#{m[:filename]}\""
            msg << 'Content-Transfer-Encoding: 7bit'
            msg << "Content-Type: text/#{m[:type]}" << 'Mime-Version: 1.0' << ''
            msg << read_part(m) << ''
          end
          msg << "--#{boundary}--"
          msg
        end

        def read_part(part)
          if part[:path]
            content = File.read part[:path]
          elsif part[:inline]
            content = part[:inline]
          else
            raise 'Invalid user data'
          end
          content.split("\n")
        end
      end
    end
  end
end
