require_relative './helper'

describe GitHub::Statsd do
  before do
    @statsd = GitHub::Statsd.new(FakeUDPSocket)
    @statsd.add_shard
    class << @statsd
      public :sampled # we need to test this
    end
  end

  after { @statsd.shards.first.clear }

  describe "#initialize" do
    it "should default client class to UDPClient" do
      statsd = GitHub::Statsd.new
      statsd.client_class.must_equal GitHub::Statsd::UDPClient
    end

    it "should allow changing client class" do
      statsd = GitHub::Statsd.new(FakeUDPSocket)
      statsd.client_class.must_equal FakeUDPSocket
    end

    it "should allow literal IPv6 addresses" do
      [
        '0000:0000:0000:0000:0000:0000:0000:0001',
        '::1'
      ].each do |ipv6_addr|
        statsd = GitHub::Statsd.new
        statsd.add_shard ipv6_addr, 8125
        statsd.shards.first.sock.addr[0].must_equal 'AF_INET6'
      end
    end
  end

  describe "#increment" do
    it "should format the message according to the statsd spec" do
      @statsd.increment('foobar')
      @statsd.shards.first.recv.must_equal ['foobar:1|c']
    end

    describe "with a sample rate" do
      before { class << @statsd; def rand; 0; end; end } # ensure delivery
      it "should format the message according to the statsd spec" do
        @statsd.increment('foobar', 0.5)
        @statsd.shards.first.recv.must_equal ['foobar:1|c|@0.5']
      end
    end
  end

  describe "#decrement" do
    it "should format the message according to the statsd spec" do
      @statsd.decrement('foobar')
      @statsd.shards.first.recv.must_equal ['foobar:-1|c']
    end

    describe "with a sample rate" do
      before { class << @statsd; def rand; 0; end; end } # ensure delivery
      it "should format the message according to the statsd spec" do
        @statsd.decrement('foobar', 0.5)
        @statsd.shards.first.recv.must_equal ['foobar:-1|c|@0.5']
      end
    end
  end

  describe "#timing" do
    it "should format the message according to the statsd spec" do
      @statsd.timing('foobar', 500)
      @statsd.shards.first.recv.must_equal ['foobar:500|ms']
    end

    describe "with a sample rate" do
      before { class << @statsd; def rand; 0; end; end } # ensure delivery
      it "should format the message according to the statsd spec" do
        @statsd.timing('foobar', 500, 0.5)
        @statsd.shards.first.recv.must_equal ['foobar:500|ms|@0.5']
      end
    end
  end

  describe "#time" do
    it "should format the message according to the statsd spec" do
      @statsd.time('foobar') { sleep(0.001); 'test' }
      data = @statsd.shards.first.recv
      key, value, unit = data.first.split(/[:|]/)
      key.must_equal "foobar"
      value.must_match /^\d\.\d+$/
      unit.must_equal "ms"
    end

    it "should return the result of the block" do
      result = @statsd.time('foobar') { sleep(0.001); 'test' }
      result.must_equal 'test'
    end

    describe "with a sample rate" do
      before { class << @statsd; def rand; 0; end; end } # ensure delivery

      it "should format the message according to the statsd spec" do
        result = @statsd.time('foobar', 0.5) { sleep(0.001); 'test' }
        data = @statsd.shards.first.recv
        key, value, unit, frequency = data.first.split(/[:|]/)
        key.must_equal "foobar"
        value.must_match /^\d\.\d+$/
        unit.must_equal "ms"
        frequency.must_equal "@0.5"
      end
    end
  end

  describe "#sampled" do
    describe "when the sample rate is 1" do
      it "should yield" do
        @statsd.sampled(1) { :yielded }.must_equal :yielded
      end
    end

    describe "when the sample rate is greater than a random value [0,1]" do
      before { class << @statsd; def rand; 0; end; end } # ensure delivery
      it "should yield" do
        @statsd.sampled(0.5) { :yielded }.must_equal :yielded
      end
    end

    describe "when the sample rate is less than a random value [0,1]" do
      before { class << @statsd; def rand; 1; end; end } # ensure no delivery
      it "should not yield" do
        @statsd.sampled(0.5) { :yielded }.must_equal nil
      end
    end

    describe "when the sample rate is equal to a random value [0,1]" do
      before { class << @statsd; def rand; 0.5; end; end } # ensure delivery
      it "should yield" do
        @statsd.sampled(0.5) { :yielded }.must_equal :yielded
      end
    end
  end

  describe "with namespace" do
    before { @statsd.namespace = 'service' }

    it "should add namespace to increment" do
      @statsd.increment('foobar')
      @statsd.shards.first.recv.must_equal ['service.foobar:1|c']
    end

    it "should add namespace to decrement" do
      @statsd.decrement('foobar')
      @statsd.shards.first.recv.must_equal ['service.foobar:-1|c']
    end

    it "should add namespace to timing" do
      @statsd.timing('foobar', 500)
      @statsd.shards.first.recv.must_equal ['service.foobar:500|ms']
    end
  end

  describe "stat names" do

    it "should accept anything as stat" do
      @statsd.increment(Object, 1)
    end

    it "should replace ruby constant delimeter with graphite package name" do
      class GitHub::Statsd::SomeClass; end
      @statsd.increment(GitHub::Statsd::SomeClass, 1)

      @statsd.shards.first.recv.must_equal ['GitHub.Statsd.SomeClass:1|c']
    end

    it "should replace statsd reserved chars in the stat name" do
      @statsd.increment('ray@hostname.blah|blah.blah:blah', 1)
      @statsd.shards.first.recv.must_equal ['ray_hostname.blah_blah.blah_blah:1|c']
    end

  end

end

describe GitHub::Statsd do
  describe "with a real UDP socket" do
    it "should actually send stuff over the socket" do
      socket = UDPSocket.new
      host, port = 'localhost', 12345
      socket.bind(host, port)

      statsd = GitHub::Statsd.new(host, port)
      statsd.increment('foobar')
      message = socket.recvfrom(16).first
      message.must_equal 'foobar:1|c'
    end
  end
end if ENV['LIVE']
