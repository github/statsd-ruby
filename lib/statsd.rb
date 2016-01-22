require 'socket'
require 'zlib'

# = Statsd: A Statsd client (https://github.com/etsy/statsd)
#
# @example Set up a global Statsd client for a server on localhost:8125
#   $statsd = Statsd.new 'localhost', 8125
# @example Send some stats
#   $statsd.increment 'garets'
#   $statsd.timing 'glork', 320
# @example Use {#time} to time the execution of a block
#   $statsd.time('account.activate') { @account.activate! }
# @example Create a namespaced statsd client and increment 'account.activate'
#   statsd = Statsd.new('localhost').tap{|sd| sd.namespace = 'account'}
#   statsd.increment 'activate'
class Statsd
  class UDPClient
    attr_reader :sock

    def initialize(address, port = nil)
      address, port = address.split(':') if address.include?(':')
      addrinfo = Addrinfo.ip(address)

      @sock = UDPSocket.new(addrinfo.pfamily)
      @sock.connect(addrinfo.ip_address, port)
    end

    def send(msg)
      sock.write(msg)
    rescue SystemCallError
      nil
    end
  end

  class SecureUDPClient < UDPClient
    def initialize(address, port, key)
      super(address, port)
      @key = key
    end

    def send(msg)
      super(signed_payload(msg))
    end

    private
    # defer loading openssl and securerandom unless needed. this shaves ~10ms off
    # of baseline require load time for environments that don't require message signing.
    def self.setup_openssl
      @sha256 ||= begin
        require 'securerandom'
        require 'openssl'
        OpenSSL::Digest::SHA256.new
      end
    end

    def signed_payload(message)
      sha256 = SecureUDPClient.setup_openssl
      payload = timestamp + nonce + message
      signature = OpenSSL::HMAC.digest(sha256, @key, payload)
      signature + payload
    end

    def timestamp
      [Time.now.to_i].pack("Q<")
    end

    def nonce
      SecureRandom.random_bytes(4)
    end
  end

  # A namespace to prepend to all statsd calls.
  attr_reader :namespace
  attr_accessor :default_sample_rate

  def namespace=(namespace)
    @namespace = namespace
    @prefix = namespace ? "#{@namespace}." : "".freeze
  end

  # All the endpoints where StatsD will report metrics
  attr_reader :shards

  #characters that will be replaced with _ in stat names
  RESERVED_CHARS_REGEX = /[\:\|\@]/

  COUNTER_TYPE = "c".freeze
  TIMING_TYPE = "ms".freeze
  GAUGE_TYPE = "g".freeze
  HISTOGRAM_TYPE = "h".freeze

  def initialize(client_class: nil, default_sample_rate: 1)
    @shards = []
    @client_class = client_class || UDPClient
    @default_sample_rate = default_sample_rate
    self.namespace = nil
  end

  def self.simple(addr, port = nil)
    self.new.add_shard(addr, port)
  end

  def add_shard(*args)
    @shards << @client_class.new(*args)
    self
  end

  def enable_buffering(buffer_size = nil)
    return if @buffering
    @shards.map! { |client| Buffer.new(client, buffer_size) }
    @buffering = true
  end

  def disable_buffering
    return unless @buffering
    flush_all
    @shards.map! { |client| client.base_client }
    @buffering = false
  end

  def flush_all
    return unless @buffering
    @shards.each { |client| client.flush }
  end


  # Sends an increment (count = 1) for the given stat to the statsd server.
  #
  # @param stat (see #count)
  # @param sample_rate (see #count)
  # @see #count
  def increment(stat, sample_rate=nil); count stat, 1, sample_rate end

  # Sends a decrement (count = -1) for the given stat to the statsd server.
  #
  # @param stat (see #count)
  # @param sample_rate (see #count)
  # @see #count
  def decrement(stat, sample_rate=nil); count stat, -1, sample_rate end

  # Sends an arbitrary count for the given stat to the statsd server.
  #
  # @param [String] stat stat name
  # @param [Integer] count count
  # @param [Integer] sample_rate sample rate, 1 for always
  def count(stat, count, sample_rate=nil); send stat, count, COUNTER_TYPE, sample_rate end

  # Sends an arbitary gauge value for the given stat to the statsd server.
  #
  # @param [String] stat stat name.
  # @param [Numeric] gauge value.
  # @example Report the current user count:
  #   $statsd.gauge('user.count', User.count)
  def gauge(stat, value)
    send stat, value, GAUGE_TYPE
  end

  # Sends a timing (in ms) for the given stat to the statsd server. The
  # sample_rate determines what percentage of the time this report is sent. The
  # statsd server then uses the sample_rate to correctly track the average
  # timing for the stat.
  #
  # @param stat stat name
  # @param [Integer] ms timing in milliseconds
  # @param [Integer] sample_rate sample rate, 1 for always
  def timing(stat, ms, sample_rate=nil); send stat, ms, TIMING_TYPE, sample_rate end

  # Reports execution time of the provided block using {#timing}.
  #
  # @param stat (see #timing)
  # @param sample_rate (see #timing)
  # @yield The operation to be timed
  # @see #timing
  # @example Report the time (in ms) taken to activate an account
  #   $statsd.time('account.activate') { @account.activate! }
  def time(stat, sample_rate=nil)
    start = Time.now
    result = yield
    timing(stat, ((Time.now - start) * 1000).round(5), sample_rate)
    result
  end

  # Sends a histogram measurement for the given stat to the statsd server. The
  # sample_rate determines what percentage of the time this report is sent. The
  # statsd server then uses the sample_rate to correctly track the average
  # for the stat.
  def histogram(stat, value, sample_rate=nil); send stat, value, HISTOGRAM_TYPE, sample_rate end

  private
  def send(stat, delta, type, sample_rate=nil)
    sample_rate ||= default_sample_rate
    return if sample_rate < 1 and rand > sample_rate

    stat = stat.to_s.dup
    stat.gsub!(/::/, ".".freeze)
    stat.gsub!(RESERVED_CHARS_REGEX, "_".freeze)

    msg = String.new
    msg << @prefix
    msg << stat
    msg << ":".freeze
    msg << delta.to_s
    msg << "|".freeze
    msg << type
    if sample_rate < 1
      msg << "|@".freeze
      msg << sample_rate.to_s
    end

    shard = select_shard(stat)
    shard.send(msg)
  end

  def select_shard(stat)
    if @shards.size == 1
      @shards.first
    else
      @shards[Zlib.crc32(stat) % @shards.size]
    end
  end

  class Buffer
    DEFAULT_BUFFER_CAP = 512

    attr_reader :base_client
    attr_accessor :flush_count

    def initialize(client, buffer_cap = nil)
      @base_client = client
      @buffer = String.new
      @buffer_cap = buffer_cap || DEFAULT_BUFFER_CAP
      @flush_count = 0
    end

    def flush
      return unless @buffer.bytesize > 0
      @base_client.send(@buffer)
      @buffer.clear
      @flush_count += 1
    end

    def send(msg)
      flush if @buffer.bytesize + msg.bytesize >= @buffer_cap
      @buffer << msg
      @buffer << "\n".freeze
      nil
    end
  end
end
