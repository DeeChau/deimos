# frozen_string_literal: true

require 'avro-patches'
require 'avro_turf'
require 'phobos'
require 'deimos/version'
require 'deimos/avro_data_encoder'
require 'deimos/avro_data_decoder'
require 'deimos/producer'
require 'deimos/active_record_producer'
require 'deimos/active_record_consumer'
require 'deimos/active_record_batch_consumer'
require 'deimos/consumer'
require 'deimos/batch_consumer'
require 'deimos/configuration'
require 'deimos/instrumentation'
require 'deimos/utils/lag_reporter'

require 'deimos/publish_backend'
require 'deimos/backends/kafka'
require 'deimos/backends/kafka_async'

require 'deimos/monkey_patches/ruby_kafka_heartbeat'
require 'deimos/monkey_patches/schema_store'
require 'deimos/monkey_patches/phobos_producer'
require 'deimos/monkey_patches/phobos_cli'

require 'deimos/railtie' if defined?(Rails)
if defined?(ActiveRecord)
  require 'deimos/kafka_source'
  require 'deimos/kafka_topic_info'
  require 'deimos/backends/db'
  require 'deimos/utils/signal_handler.rb'
  require 'deimos/utils/executor.rb'
  require 'deimos/utils/db_producer.rb'
end
require 'deimos/utils/inline_consumer'
require 'yaml'
require 'erb'

# Parent module.
module Deimos
  class << self
    attr_accessor :config

    # Configure Deimos.
    def configure
      first_time_config = self.config.nil?
      self.config ||= Configuration.new
      old_config = self.config.dup
      yield(config)

      # Don't re-configure Phobos every time
      if first_time_config || config.phobos_config_changed?(old_config)

        file = config.phobos_config_file
        phobos_config = YAML.load(ERB.new(File.read(File.expand_path(file))).result)

        configure_kafka_for_phobos(phobos_config)
        configure_loggers(phobos_config)

        Phobos.configure(phobos_config)

        validate_consumers
      end

      validate_db_backend if self.config.publish_backend == :db
    end

    # Ensure everything is set up correctly for the DB backend.
    def validate_db_backend
      begin
        require 'activerecord-import'
      rescue LoadError
        raise 'Cannot set publish_backend to :db without activerecord-import! Please add it to your Gemfile.'
      end
      if Phobos.config.producer_hash[:required_acks] != :all
        raise 'Cannot set publish_backend to :db unless required_acks is set to ":all" in phobos.yml!'
      end
    end

    # Start the DB producers to send Kafka messages.
    # @param thread_count [Integer] the number of threads to start.
    def start_db_backend!(thread_count: 1)
      if self.config.publish_backend != :db
        raise('Publish backend is not set to :db, exiting')
      end

      if thread_count.nil? || thread_count.zero?
        raise('Thread count is not given or set to zero, exiting')
      end

      producers = (1..thread_count).map do
        Deimos::Utils::DbProducer.
          new(self.config.db_producer.logger || self.config.logger)
      end
      executor = Deimos::Utils::Executor.new(producers,
                                             sleep_seconds: 5,
                                             logger: self.config.logger)
      signal_handler = Deimos::Utils::SignalHandler.new(executor)
      signal_handler.run!
    end

    # @param phobos_config [Hash]
    def configure_kafka_for_phobos(phobos_config)
      if config.ssl_enabled
        %w(ssl_ca_cert ssl_client_cert ssl_client_cert_key).each do |key|
          next if config.send(key).blank?

          phobos_config['kafka'][key] = ssl_var_contents(config.send(key))
        end
      end
      phobos_config['kafka']['seed_brokers'] = config.seed_broker if config.seed_broker
    end

    # @param phobos_config [Hash]
    def configure_loggers(phobos_config)
      phobos_config['custom_logger'] = config.phobos_logger
      phobos_config['custom_kafka_logger'] = config.kafka_logger
    end

    # @param filename [String] a file to read, or the contents of the SSL var
    # @return [String] the contents of the file
    def ssl_var_contents(filename)
      File.exist?(filename) ? File.read(filename) : filename
    end

    # Validate that consumers are configured correctly, including their
    # delivery mode.
    def validate_consumers
      Phobos.config.listeners.each do |listener|
        handler_class = listener.handler.constantize
        delivery = listener.delivery

        # Validate that Deimos consumers use proper delivery configs
        if handler_class < Deimos::BatchConsumer
          unless delivery == 'inline_batch'
            raise "BatchConsumer #{listener.handler} must have delivery set to"\
              ' `inline_batch`'
          end
        elsif handler_class < Deimos::Consumer
          if delivery.present? && !%w(message batch).include?(delivery)
            raise "Non-batch Consumer #{listener.handler} must have delivery"\
              ' set to `message` or `batch`'
          end
        end
      end
    end
  end
end

at_exit do
  begin
    Deimos::Backends::KafkaAsync.shutdown_producer
    Deimos::Backends::Kafka.shutdown_producer
  rescue StandardError => e
    Deimos.config.logger.error(
      "Error closing producer on shutdown: #{e.message} #{e.backtrace.join("\n")}"
    )
  end
end
