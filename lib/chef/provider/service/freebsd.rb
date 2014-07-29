#
# Author:: Bryan McLellan (btm@loftninjas.org)
# Copyright:: Copyright (c) 2009 Bryan McLellan
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/resource/service'
require 'chef/provider/service/init'
require 'chef/mixin/command'

class Chef
  class Provider
    class Service
      class Freebsd < Chef::Provider::Service::Init


        def load_current_resource
          @current_resource = Chef::Resource::Service.new(@new_resource.name)
          @current_resource.service_name(@new_resource.service_name)
          @rcd_script_found = true
          @enabled_state_found = false
          # Determine if we're talking about /etc/rc.d or /usr/local/etc/rc.d
          if ::File.exists?("/etc/rc.d/#{current_resource.service_name}")
            @init_command = "/etc/rc.d/#{current_resource.service_name}"
          elsif ::File.exists?("/usr/local/etc/rc.d/#{current_resource.service_name}")
            @init_command = "/usr/local/etc/rc.d/#{current_resource.service_name}"
          else
            @rcd_script_found = false
            return
          end
          Chef::Log.debug("#{@current_resource} found at #{@init_command}")
          determine_current_status!
          # Default to disabled if the service doesn't currently exist
          # at all
          var_name = service_enable_variable_name
          if ::File.exists?("/etc/rc.conf") && var_name
            read_rc_conf.each do |line|
              case line
              when /#{Regexp.escape(var_name)}="(\w+)"/
                @enabled_state_found = true
                if $1 =~ /[Yy][Ee][Ss]/
                  @current_resource.enabled true
                elsif $1 =~ /[Nn][Oo][Nn]?[Oo]?[Nn]?[Ee]?/
                  @current_resource.enabled false
                end
              end
            end
          end
          unless @current_resource.enabled
            Chef::Log.debug("#{@new_resource.name} enable/disable state unknown")
            @current_resource.enabled false
          end

          @current_resource
        end

        def define_resource_requirements
          shared_resource_requirements
          requirements.assert(:start, :enable, :reload, :restart) do |a|
            a.assertion { @rcd_script_found }
            a.failure_message Chef::Exceptions::Service, "#{@new_resource}: unable to locate the rc.d script"
          end

          requirements.assert(:all_actions) do |a|
            a.assertion { @enabled_state_found }
            # for consistentcy with original behavior, this will not fail in non-whyrun mode;
            # rather it will silently set enabled state=>false
            a.whyrun "Unable to determine enabled/disabled state, assuming this will be correct for an actual run.  Assuming disabled."
          end

          requirements.assert(:start, :enable, :reload, :restart) do |a|
            a.assertion { @rcd_script_found && service_enable_variable_name != nil }
            a.failure_message Chef::Exceptions::Service, "Could not find the service name in #{@init_command} and rcvar"
            # No recovery in whyrun mode - the init file is present but not correct.
          end
        end

        def start_service
          if @new_resource.start_command
            super
          else
            shell_out!("#{@init_command} faststart")
          end
        end

        def stop_service
          if @new_resource.stop_command
            super
          else
            shell_out!("#{@init_command} faststop")
          end
        end

        def restart_service
          if @new_resource.restart_command

            super
          elsif @new_resource.supports[:restart]
            shell_out!("#{@init_command} fastrestart")
          else
            stop_service
            sleep 1
            start_service
          end
        end

        def read_rc_conf
          ::File.open("/etc/rc.conf", 'r') { |file| file.readlines }
        end

        def write_rc_conf(lines)
          ::File.open("/etc/rc.conf", 'w') do |file|
            lines.each { |line| file.puts(line) }
          end
        end

        # The variable name used in /etc/rc.conf for enabling this service
        def service_enable_variable_name
          # Look for name="foo" in the shell script @init_command. Use this for determining the variable name in /etc/rc.conf
          # corresponding to this service
          # For example: to enable the service mysql-server with the init command /usr/local/etc/rc.d/mysql-server, you need
          # to set mysql_enable="YES" in /etc/rc.conf$
          if @rcd_script_found
            ::File.open(@init_command) do |rcscript|
              rcscript.each_line do |line|
                if line =~ /^name="?(\w+)"?/
                  return $1 + "_enable"
                end
              end
            end
            # some scripts support multiple instances through symlinks such as openvpn.
            # We should get the service name from rcvar.
            Chef::Log.debug("name=\"service\" not found at #{@init_command}. falling back to rcvar")
            sn = shell_out!("#{@init_command} rcvar").stdout[/(\w+_enable)=/, 1]
            return sn
          end
          # Fallback allows us to keep running in whyrun mode when
          # the script does not exist.
          @new_resource.service_name
        end

        def set_service_enable(value)
          lines = read_rc_conf
          # Remove line that set the old value
          lines.delete_if { |line| line =~ /#{Regexp.escape(service_enable_variable_name)}/ }
          # And append the line that sets the new value at the end
          lines << "#{service_enable_variable_name}=\"#{value}\""
          write_rc_conf(lines)
        end

        def enable_service()
          set_service_enable("YES") unless @current_resource.enabled
        end

        def disable_service()
          set_service_enable("NO") if @current_resource.enabled
        end

      end
    end
  end
end
