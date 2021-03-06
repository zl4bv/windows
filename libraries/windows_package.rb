require 'chef/resource/lwrp_base'
require 'chef/provider/lwrp_base'

if RUBY_PLATFORM =~ /mswin|mingw32|windows/
  require 'win32/registry'
end

require 'chef/mixin/shell_out'
require 'chef/mixin/language'
class Chef
  class Provider
    class WindowsCookbookPackage < Chef::Provider::LWRPBase
      include Chef::Mixin::ShellOut
      include Windows::Helper

      # the logic in all action methods mirror that of
      # the Chef::Provider::Package which will make
      # refactoring into core chef easy

      action :install do
        # If we specified a version, and it's not the current version, move to the specified version
        if @new_resource.version != nil && @new_resource.version != @current_resource.version
          install_version = @new_resource.version
        # If it's not installed at all, install it
        elsif @current_resource.version == nil
          install_version = candidate_version
        end

        if install_version
          Chef::Log.info("Installing #{@new_resource} version #{install_version}")
          status = install_package(@new_resource.package_name, install_version)
          if status
            new_resource.updated_by_last_action(true)
          end
        end
      end

      action :upgrade do
        if @current_resource.version != candidate_version
          orig_version = @current_resource.version || "uninstalled"
          Chef::Log.info("Upgrading #{@new_resource} version from #{orig_version} to #{candidate_version}")
          status = upgrade_package(@new_resource.package_name, candidate_version)
          if status
            new_resource.updated_by_last_action(true)
          end
        end
      end

      action :remove do
        if removing_package?
          Chef::Log.info("Removing #{@new_resource}")
          remove_package(@current_resource.package_name, @new_resource.version)
          new_resource.updated_by_last_action(true)
        else
        end
      end

      def removing_package?
        if @current_resource.version.nil?
          false # nothing to remove
        elsif @new_resource.version.nil?
          true # remove any version of a package
        elsif @new_resource.version == @current_resource.version
          true # remove the version we have
        else
          false # we don't have the version we want to remove
        end
      end

      def expand_options(options)
        options ? " #{options}" : ""
      end

      # these methods are the required overrides of
      # a provider that extends from Chef::Provider::Package
      # so refactoring into core Chef should be easy

      def load_current_resource
        @current_resource = Chef::Resource::WindowsPackage.new(@new_resource.name)
        @current_resource.package_name(@new_resource.package_name)
        @current_resource.version(nil)

        unless current_installed_version.nil?
          @current_resource.version(current_installed_version)
        end

        @current_resource
      end

      def current_installed_version
        @current_installed_version ||= begin
          if installed_packages.include?(@new_resource.package_name)
            installed_packages[@new_resource.package_name][:version]
          end
        end
      end

      def candidate_version
        @candidate_version ||= begin
          @new_resource.version || 'latest'
        end
      end

      def install_package(name,version)
        Chef::Log.debug("Processing #{@new_resource} as a #{installer_type} installer.")
        install_args = [cached_file(@new_resource.source, @new_resource.checksum), expand_options(unattended_installation_flags), expand_options(@new_resource.options)]
        Chef::Log.info("Starting installation...this could take awhile.")
        Chef::Log.debug "Install command: #{ sprintf(install_command_template, *install_args) }"
        shell_out!(sprintf(install_command_template, *install_args), {:timeout => @new_resource.timeout, :returns => @new_resource.success_codes})
      end

      def remove_package(name, version)
        uninstall_string = installed_packages[@new_resource.package_name][:uninstall_string]
        Chef::Log.info("Registry provided uninstall string for #{@new_resource} is '#{uninstall_string}'")
        uninstall_command = begin
          if uninstall_string =~ /msiexec/i
            "#{uninstall_string} /qn"
          else
            uninstall_string.gsub!('"','')
            "start \"\" /wait /d\"#{::File.dirname(uninstall_string)}\" #{::File.basename(uninstall_string)}#{expand_options(@new_resource.options)} /S & exit %%%%ERRORLEVEL%%%%"
          end
        end
        Chef::Log.info("Removing #{@new_resource} with uninstall command '#{uninstall_command}'")
        shell_out!(uninstall_command, {:returns => @new_resource.success_codes})
      end

      private

      def install_command_template
        case installer_type
        when :msi
          "msiexec%2$s \"%1$s\"%3$s"
        when :msu
          "musa%2$s \"%1$s\"%3$s"
        else
          "start \"\" /wait \"%1$s\"%2$s%3$s & exit %%%%ERRORLEVEL%%%%"
        end
      end


      # http://unattended.sourceforge.net/installers.php
      def unattended_installation_flags
        case installer_type
        when :msi
          # this is no-ui
          "/qn /i"
        when :msu
          # this is no-ui and no-restart
          "/quiet /norestart"
        when :installshield
          "/s /sms"
        when :nsis
          "/S /NCRC"
        when :inno
          #"/sp- /silent /norestart"
          "/verysilent /norestart"
        when :wise
          "/s"
        else
        end
      end

      def installed_packages
        @installed_packages || begin
          installed_packages = {}
          # Computer\HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall
          installed_packages.merge!(extract_installed_packages_from_key(::Win32::Registry::HKEY_LOCAL_MACHINE)) #rescue nil
          # 64-bit registry view
          # Computer\HKEY_LOCAL_MACHINE\Software\Wow6464Node\Microsoft\Windows\CurrentVersion\Uninstall
          installed_packages.merge!(extract_installed_packages_from_key(::Win32::Registry::HKEY_LOCAL_MACHINE, (::Win32::Registry::Constants::KEY_READ | 0x0100))) #rescue nil
          # 32-bit registry view
          # Computer\HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall
          installed_packages.merge!(extract_installed_packages_from_key(::Win32::Registry::HKEY_LOCAL_MACHINE, (::Win32::Registry::Constants::KEY_READ | 0x0200))) #rescue nil
          # Computer\HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall
          installed_packages.merge!(extract_installed_packages_from_key(::Win32::Registry::HKEY_CURRENT_USER)) #rescue nil
          installed_packages
        end
      end

      def extract_installed_packages_from_key(hkey = ::Win32::Registry::HKEY_LOCAL_MACHINE, desired = ::Win32::Registry::Constants::KEY_READ)
        uninstall_subkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
        packages = {}
        begin
          ::Win32::Registry.open(hkey, uninstall_subkey, desired) do |reg|
            reg.each_key do |key, wtime|
              begin
                k = reg.open(key, desired)
                display_name = k["DisplayName"] rescue nil
                version = k["DisplayVersion"] rescue "NO VERSION"
                uninstall_string = k["UninstallString"] rescue nil
                if display_name
                  packages[display_name] = {:name => display_name,
                                            :version => version,
                                            :uninstall_string => uninstall_string}
                end
              rescue ::Win32::Registry::Error
              end
            end
          end
        rescue ::Win32::Registry::Error
        end
        packages
      end

      def installer_type
        @installer_type || begin
          if @new_resource.installer_type
            @new_resource.installer_type
          else
            basename = ::File.basename(cached_file(@new_resource.source, @new_resource.checksum))
            if basename.split(".").last.downcase == "msi" # Microsoft MSI
              :msi
            elsif basename.split(".").last.downcase == "msu" # Microsoft MSU
              :msu
            else
              # search the binary file for installer type
              contents = ::Kernel.open(::File.expand_path(cached_file(@new_resource.source)), "rb") {|io| io.read } # TODO limit data read in
              case contents
              when /inno/i # Inno Setup
                :inno
              when /wise/i # Wise InstallMaster
                :wise
              when /nsis/i # Nullsoft Scriptable Install System
                :nsis
              else
                # if file is named 'setup.exe' assume installshield
                if basename == "setup.exe"
                  :installshield
                else
                  raise Chef::Exceptions::AttributeNotFound, "installer_type could not be determined, please set manually"
                end
              end
            end
          end
        end
      end
    end
  end
end


class Chef
  class Resource
    class WindowsCookbookPackage < Chef::Resource::LWRPBase
      if Gem::Version.new(Chef::VERSION) >= Gem::Version.new('12')
        provides :windows_package, os: "windows"
      end
      actions :install, :remove

      default_action :install

      attribute :package_name, :kind_of => String, :name_attribute => true
      attribute :source, :kind_of => String, :required => true
      attribute :version, :kind_of => String
      attribute :options, :kind_of => String
      attribute :installer_type, :kind_of => Symbol, :default => nil, :equal_to => [:msi, :inno, :nsis, :wise, :installshield, :custom]
      attribute :checksum, :kind_of => String
      attribute :timeout, :kind_of => Integer, :default => 600
      attribute :success_codes, :kind_of => Array, :default => [0, 42, 127]

      self.resource_name = 'windows_package'
      def initialize(*args)
        super
        @provider = Chef::Provider::WindowsCookbookPackage
      end
    end
  end
end

if Gem::Version.new(Chef::VERSION) < Gem::Version.new('12')
  Chef::Resource.send(:remove_const, :WindowsPackage) if defined? Chef::Resource::WindowsPackage
  Chef::Resource.const_set("WindowsPackage", Chef::Resource::WindowsCookbookPackage)
end
