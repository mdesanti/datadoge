require 'datadoge/version'
require 'gem_config'
require 'datadog/statsd'

module Datadoge
  include GemConfig::Base

  with_configuration do
    has :environments, classes: Array, default: ['production']
    has :client, classes: Datadog::Statsd, default: Datadog::Statsd.new
    has :namespace, classes: String, default: 'rails'
  end

  class Railtie < Rails::Railtie
    initializer "datadoge.configure_rails_initialization" do |app|
      $statsd = Datadoge.configuration.client

      ActiveSupport::Notifications.subscribe /process_action.action_controller/ do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        controller = "controller:#{event.payload[:controller]}"
        action = "action:#{event.payload[:action]}"
        format = "format:#{event.payload[:format] || 'all'}"
        format = "format:all" if format == "format:*/*"
        host = "host:#{ENV.fetch('INSTRUMENTATION_HOSTNAME', ENV['HOSTNAME'])}"
        status = event.payload[:status]
        tags = [controller, action, format, host]
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags, :measurement => "request.total_duration", :value => event.duration
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags,  :measurement => "database.query.time", :value => event.payload[:db_runtime]
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags,  :measurement => "web.view.time", :value => event.payload[:view_runtime]
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags,  :measurement => "request.status.#{event.payload[:status]}", :value => event.payload[:status]
        ActiveSupport::Notifications.instrument :performance, :tags => tags,  :measurement => "request.status.#{status}"
      end

      ActiveSupport::Notifications.subscribe /performance/ do |name, start, finish, id, payload|
        send_event_to_statsd(name, payload) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(name, payload)
        # Datadog gets really grumpy with blank/nil Ruby values.
        value = payload[:value]
        return if value.blank?

        action = payload[:action] || :increment
        measurement = payload[:measurement]
        tags = payload[:tags]
        key_name = "#{Datadoge.configuration.namespace.to_s}.#{name.to_s.capitalize}.#{measurement}"
        if action == :increment
          $statsd.increment key_name, :tags => tags
        else
          $statsd.histogram key_name, value, :tags => tags
        end
      end
    end
  end
end
