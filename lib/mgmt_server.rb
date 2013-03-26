require 'socket'

class Statsd
  class MgmtServer

    METHODS_ALLOWED = ["counters", "timers", "gauges", "sets"]

    def initialize(host="localhost", port=8126)
      @host = host
      @port = port
    end

    def request_server(stat)
      @mgmt_server ||= TCPSocket.new(@host, @port)
      @mgmt_server.puts stat
      parse_response
    end

    def parse_response
      #return if @parsing_stats
      #@parsing_stats = true

      response = @mgmt_server.gets.strip
      #return ERROR if statsd returns error
      return "ERROR" if ( response == "ERROR" )

      #concatenate the data to a string and return
      #statsd returns END on completion
      while( (l = @mgmt_server.gets.strip) != "END")
        response += l
      end
      #@parsing_stats = false
      response
    end

    def method_missing(m, *args)
      raise NoMethodError if !(METHODS_ALLOWED.include?(m.to_s))
      Statsd::MgmtServer.new.send(:request_server, m.to_sym)
    end
  end
end
