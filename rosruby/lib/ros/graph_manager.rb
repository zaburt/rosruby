# ros/graph_manager.rb
#
# License: BSD
#
# Copyright (C) 2012  Takashi Ogura <t.ogura@gmail.com>
#
#=Manager of ROS graph
#
# this contains all subscribers, publishers, service_servers of a node.
# Master API document is http://ros.org/wiki/ROS/Master_API
# Slave API is http://ros.org/wiki/ROS/Slave_API
#
require 'xmlrpc/server'
require 'ros/master_proxy'
require 'timeout'

module ROS

  #=Manager of ROS graph
  #
  # this contains all subscribers, publishers, service_servers of a node.
  # Master API document is http://ros.org/wiki/ROS/Master_API
  # Slave API is http://ros.org/wiki/ROS/Slave_API
  #
  # connect with master and manage pub/sub and services
  #
  class GraphManager

    # max number of connection with other slave nodes
    MAX_CONNECTION = 100

    attr_reader :publishers, :subscribers, :service_servers, :host, :port

    ##
    # add xmlrpc handlers for slave connections.
    # Then start serve thread.
    #
    def initialize(caller_id, node)
      @caller_id = caller_id
      @node = node
      @host = node.host
      @port = get_available_port
      @master = MasterProxy.new(@caller_id, @node.master_uri, get_uri)
      @server = XMLRPC::Server.new(@port, @host, MAX_CONNECTION, $stderr, false, false)
      @publishers = []
      @subscribers = []
      @service_servers = []
      @parameter_subscribers = []
      @server.set_default_handler do |method, *args|
        p 'call!! unhandled'
        p method
        p args
        [0, "I DON'T KNOW", 0]
      end

      @server.add_handler('getBusStats') do |caller_id|
        pubstats = @publishers.map do |pub|
          [pub.topic_name, pub.topic_type.type, pub.get_connection_data]
        end
        substats = @subscribers.map do |sub|
          [sub.topic_name, sub.get_connection_data]
        end
        servstats = @service_servers.map do |service|
          [service.get_connection_data]
        end
        [1, "stats", [pubstats, substats, servstats]]
      end

      @server.add_handler('getMasterUri') do |caller_id|
        [1, "master", @node.master_uri]
      end

      @server.add_handler('getSubscriptions') do |caller_id|
        topic_list = @subscribers.map do |sub|
          [sub.topic_name, sub.topic_type.type]
        end
        [1, "ok", topic_list]
      end

      @server.add_handler('getPublications') do |caller_id|
        topic_list = @publishers.map do |pub|
          [pub.topic_name, pub.topic_type.type]
        end
        [1, "ok", topic_list]
      end

      @server.add_handler('paramUpdate') do |caller_id, parameter_key, parameter_value|
        @parameter_subscribers.each do |param|
          # parameter_key has / in the end
          if param.key == @node.canonicalize_name(parameter_key)
            param.call(parameter_value)
          end
        end
        [1, "ok", 0]
      end

      @server.add_handler('requestTopic') do |caller_id, topic, protocols|
        message = [0, "I DON'T KNOW", 0]
        protocols.select {|x| x[0] == 'TCPROS'}.each do |protocol|
          @publishers.select {|pub| pub.topic_name == topic}.each do |publisher|
            connection = publisher.add_connection(caller_id)
            message = [1, "OK! WAIT!!!", ['TCPROS',
                                          connection.host,
                                          connection.port]]
          end
        end
        message
      end

      @server.add_handler('shutdown') do |caller_id, msg|
        puts "shutting down by master request: #{msg}"
        @node.shutdown
        [1, 'shutdown ok', 0]
      end

      @server.add_handler('getPid') do |caller_id|
        [1, "pid ok", Process.pid]
      end

      @server.add_handler('getBusInfo') do |caller_id|
        info = []
        @publishers.each do |publisher|
          info.concat(publisher.get_connection_info)
        end
        @subscribers.each do |subscriber|
          info.concat(subscriber.get_connection_info)
        end
        [1, "getBusInfo ok", info]
      end

      @server.add_handler('publisherUpdate') do |caller_id, topic, publishers|
        @subscribers.select {|sub| sub.topic_name == topic}.each do |sub|
          publishers.select {|uri| not sub.has_connection_with?(uri)}.each do |uri|
            sub.add_connection(uri)
          end
          sub.get_connected_uri.select {|uri| not publishers.include?(uri)}.each do |uri|
            sub.drop_connection(uri)
          end
        end
        [1, "OK! Updated!!", 0]
      end

      @thread = Thread.new do
        @server.serve
      end

    end

    ##
    # get available port number by opening port 0.
    # @return port_num
    #
    def get_available_port
      server = TCPServer.open(0)
      saddr = server.getsockname
      port = Socket.unpack_sockaddr_in(saddr)[0]
      server.close
      port
    end

    ##
    # get this slave node's URI
    # @return uri
    #
    def get_uri
      "http://" + @host + ":" + @port.to_s + "/"
    end

    ##
    # wait until service is available
    # @param [in] service_name
    # @param [in] timeout_sec
    # @return true: available, false: time out
    #
    def wait_for_service(service_name, timeout_sec)
      begin
        timeout(timeout_sec) do
          while @node.ok?
            if @master.lookup_service(service_name)
              return true
            end
            sleep(0.1)
          end
        end
      rescue Timeout::Error
        puts "time outed for wait service #{service_name}"
        return nil
      rescue
        raise "connection with master failed. master = #{@node.master_uri}"
      end
    end

    ##
    # register a service to master,
    # and add it in the controlling server list.
    # raise if fail.
    def add_service_server(service_server)
      @master.register_service(service_server.service_name,
                               service_server.service_uri)
      service_server.set_manager(self)
      @service_servers.push(service_server)
    end


    ##
    # register a subscriber to master. raise if fail.
    #
    def add_subscriber(subscriber)
      uris = @master.register_subscriber(subscriber.topic_name,
                                         subscriber.topic_type.type)
      subscriber.set_manager(self)
      uris.each do |publisher_uri|
        subscriber.add_connection(publisher_uri)
      end
      @subscribers.push(subscriber)
      subscriber
    end

    ##
    # register callback for paramUpdate
    #
    def add_parameter_subscriber(subscriber)
      @parameter_subscribers.push(subscriber)
      @master.subscribe_param(subscriber.key)
    end

    ##
    # register a publisher. raise if fail.
    #
    def add_publisher(publisher)
      @master.register_publisher(publisher.topic_name,
                                 publisher.topic_type.type)
      publisher.set_manager(self)
      @publishers.push(publisher)
      publisher
    end

    ##
    # process all messages of subscribers
    #
    def spin_once
      @subscribers.each {|subscriber| subscriber.process_queue}
    end

    def shutdown_publisher(publisher)
      @master.unregister_publisher(publisher.topic_name)
      @publishers.delete(publisher) do |pub|
        raise "publisher not found"
      end
      publisher.close
    end

    def shutdown_subscriber(subscriber)
      @master.unregister_subscriber(subscriber.topic_name)
      @subscribers.delete(subscriber) do |pub|
        raise "subscriber not found"
      end
      subscriber.close
    end

    def shutdown_service_server(service)
      @master.unregister_service(service.service_name,
                                 service.service_uri)
      @service_servers.delete(service) do |pub|
        raise "service_server not found"
      end
      service.close
    end

    ##
    # shutdown this slave node.
    # shutdown the xmlrpc server and all pub/sub connections.
    # and delelte all pub/sub instance from connection list
    def shutdown
      @server.shutdown
      if not @thread.join(0.1)
        Thread::kill(@thread)
      end
      @publishers.each do |publisher|
        @master.unregister_publisher(publisher.topic_name)
        publisher.close
      end
      @publishers = nil

      @subscribers.each do |subscriber|
        @master.unregister_subscriber(subscriber.topic_name)
        subscriber.close
      end
      @subscribers = nil

      @service_servers.each do |service|
        @master.unregister_service(service.service_name,
                                   service.service_uri)
        service.close
      end
      @service_servers = nil

    end

  end
end