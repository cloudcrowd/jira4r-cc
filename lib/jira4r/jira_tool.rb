################################################################################
#  Copyright 2006-2009 Codehaus Foundation
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
################################################################################
require 'logger'

#It is the responsibility of the caller to ensure SOAP4R is installed and working correctly
#require 'rubygems'
#gem 'soap4r'

module Jira4R
    class JiraTool
        attr_accessor :enhanced

        def self.deprecate(old_method, new_method)
            define_method(old_method) do |*args, &block|
                @logger.warn("Warning: #{old_method}() is deprecated in the JIRA API. Use #{new_method}()")
                send(new_method, *args, &block)
            end
        end

        deprecate :getProjectNoScheme, :getProjectNoSchemes
        deprecate :getProject, :getProjectByKey

        # Create a new JiraTool
        #
        # where:
        # version ... the version of the SOAP API you wish to use - currently supported versions  [ 2 ]
        # base_url ... the base URL of the JIRA instance - eg. http://confluence.atlassian.com
        def initialize(version, base_url)
            @version = version
            @base_url = base_url
            # don't assume everyone automatically wants to see debug crap
            # spewed to the console
            logger = Logger.new(STDERR)
            logger.level = 4
            @logger = logger
            @endpoint_url = "#{@base_url}/rpc/soap/jirasoapservice-v#{version}"
        end

        #Assign a new logger to the tool. By default a STDERR logger is used.
        def logger=(logger)
            @logger = logger
        end

        def log_level=(log_level)
            @logger.level = log_level
        end

        def http_auth(http_username, http_password, http_realm)
            @http_username = http_username
            @http_password = http_password
            @http_realm = http_realm
        end

        #Retrieve the driver, creating as required.
        def driver()
            if not @driver
                @logger.info( "Connecting driver to #{@endpoint_url}" )

                require "jira4r/v#{@version}/jiraService.rb"
                require "jira4r/v#{@version}/JiraSoapServiceDriver.rb"
                require "jira4r/v#{@version}/jiraServiceMappingRegistry.rb"

                service_classname = "Jira4R::V#{@version}::JiraSoapService"
                @logger.info("Service: #{service_classname}")
                service = eval(service_classname)
                @driver = service.send(:new, @endpoint_url)

                if not ( @http_realm.nil? or @http_username.nil? or @http_password.nil? )
                    @driver.options["protocol.http.basic_auth"] << [ @http_realm, @http_username, @http_password ]
                end
            end
            @driver
        end

        #Assign a wiredump file prefix to the driver.
        def wiredump_file_base=(base)
            driver().wiredump_file_base = base
        end


        #Login to the JIRA instance, storing the token for later calls.
        #
        #This is typically the first call that is made on the JiraTool.
        def login(username, password)
            @token = driver().login(username, password)
        end

        #Clients should avoid using the authentication token directly.
        def token()
            @token
        end

        #Call a method on the driver, adding in the authentication token previously determined using login()
        def call_driver(method_name, *args)
            @logger.debug("Finding method #{method_name}")
            method = driver().method(method_name)

            if args.length > 0
                method.call(@token, *args)
            else
                method.call(@token)
            end
        end

        #Retrieve a project without the associated PermissionScheme.
        #This will be significantly faster for larger Jira installations.
        #See: JRA-10660

        def getProjectNoSchemes(key)
            self.getProjectsNoSchemes().find { |project| project.key == key }
        end

        def getProjectByKey( projectKey )
            begin
                return call_driver( "getProjectByKey", projectKey )
            rescue SOAP::FaultError => soap_error
                #XXX surely there is a better way to detect this kind of condition in the JIRA server
                if (soap_error.faultcode.to_s == "soapenv:Server.userException") and
                        (soap_error.faultstring.to_s =~ /No project could be found with key '#{projectKey}'/)
                    return nil
                else
                    raise soap_error
                end
            end
        end

        def getGroup( groupName )
            begin
                return call_driver( "getGroup", groupName )
            rescue SOAP::FaultError => soap_error
                #XXX surely there is a better way to detect this kind of condition in the JIRA server
                if soap_error.faultcode.to_s == "soapenv:Server.userException" and soap_error.faultstring.to_s == "com.atlassian.jira.rpc.exception.RemoteValidationException: no group found for that groupName: #{groupName}"
                    return nil
                else
                    raise soap_error
                end
            end
        end

        def getProjectRoleByName( projectRoleName )
            getProjectRoles.each{ |projectRole|
                return projectRole if projectRole.name == projectRoleName
            }
        end

        def getPermissionScheme( permissionSchemeName )
            self.getPermissionSchemes().each { |permission_scheme|
                return permission_scheme if permission_scheme.name == permissionSchemeName
            }
            return nil
        end

        def getNotificationScheme( notificationSchemeName )
            self.getNotificationSchemes().each { |notification_scheme|
                return notification_scheme if notification_scheme.name == notificationSchemeName
            }
            return nil
        end

        def getPermission( permissionName )
            if not @permissions
                @permissions = self.getAllPermissions()
            end

            @permissions.each { |permission|
                return permission if permission.name.downcase == permissionName.downcase
            }

            @logger.warn("No permission #{permissionName} found")
            return nil
        end

        def findPermission(allowedPermissions, permissionName)
            allowedPermissions.each { |allowedPermission|
                @logger.debug("Checking #{allowedPermission.name} against #{permissionName} ")
                return allowedPermission if allowedPermission.name == permissionName
            }
            return nil
        end

        def findEntityInPermissionMapping(permissionMapping, entityName)
            permissionMapping.remoteEntities.each { |entity|
                return entity if entity.name == entityName
            }
            return nil
        end

        #Removes entity
        def setPermissions( permissionScheme, allowedPermissions, entity)
            allowedPermissions = [ allowedPermissions ].flatten.compact
            #Remove permissions that are no longer allowed
            permissionScheme.permissionMappings.each { |mapping|
                next unless findEntityInPermissionMapping(mapping, entity.name)

                allowedPermission = findPermission(allowedPermissions, mapping.permission.name)
                if allowedPermission
                    @logger.warn("Already has #{allowedPermission.name} in #{permissionScheme.name} for #{entity.name}")
                    allowedPermissions.delete(allowedPermission)
                    next
                end

                @logger.debug("Deleting #{mapping.permission.name} from #{permissionScheme.name} for #{entity.name}")
                deletePermissionFrom( permissionScheme, mapping.permission, entity)
            }

            @logger.debug(allowedPermissions.inspect)
            allowedPermissions.each { |allowedPermission|
                @logger.debug("Granting #{allowedPermission.name} to #{permissionScheme.name} for #{entity.name}")
                addPermissionTo(permissionScheme, allowedPermission, entity)
            }
        end

        private

        def fix_args(args)
            args.collect do |arg|
                if arg == nil
                    SOAP::SOAPNil.new
                else
                    arg
                end
            end
        end

        def method_missing(method_name, *args)
            args = fix_args(args)
            call_driver(method_name, *args)
        end
    end
end
