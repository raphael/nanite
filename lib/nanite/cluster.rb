module Nanite
  class Cluster
    attr_reader :agent_timeout, :nanites, :reaper, :serializer, :identity, :amq, :redis, :mapper

    def initialize(amq, agent_timeout, identity, serializer, mapper, redis=nil)
      @amq = amq
      @agent_timeout = agent_timeout
      @identity = identity
      @serializer = serializer
      @mapper = mapper
      @redis = redis
      @security = SecurityProvider.get
      if redis
        Nanite::Log.info("using redis for state storage")
        require 'nanite/state'
        @nanites = ::Nanite::State.new(redis)
      else
        require 'nanite/local_state'
        @nanites = Nanite::LocalState.new
      end
      @reaper = Reaper.new(agent_timeout)
      setup_queues
    end

    # determine which nanites should receive the given request
    def targets_for(request)
      return [request.target] if request.target
      __send__(request.selector, request.type, request.tags).collect {|name, state| name }
    end

    # adds nanite to nanites map: key is nanite's identity
    # and value is a services/status pair implemented
    # as a hash
    def register(reg)
      case reg
      when Register
        if @security.authorize_registration(reg)
          nanites[reg.identity] = { :services => reg.services, :status => reg.status, :tags => reg.tags }
          reaper.timeout(reg.identity, agent_timeout + 1) { nanites.delete(reg.identity) }
          Nanite::Log.info("registered: #{reg.identity}, #{nanites[reg.identity].inspect}")
        else
          Nanite::Log.warning("registration of #{reg.inspect} not authorized")
        end
      when UnRegister
        nanites.delete(reg.identity)
        Nanite::Log.info("un-registering: #{reg.identity}")
      end
    end

    def route(request, targets)
      EM.next_tick { targets.map { |target| publish(request, target) } }
    end

    def publish(request, target)
      # We need to initialize the 'target' field of the request object so that the serializer has
      # access to it.
      begin
        old_target = request.target
        request.target = target unless target == 'mapper-offline'
        amq.queue(target).publish(serializer.dump(request), :persistent => request.persistent)
      ensure
        request.target = old_target
      end
    end

    protected

    # updates nanite information (last ping timestamps, status)
    # when heartbeat message is received
    def handle_ping(ping)
      if nanite = nanites[ping.identity]
        nanite[:status] = ping.status
        reaper.reset_with_autoregister_hack(ping.identity, agent_timeout + 1) { nanites.delete(ping.identity) }
      else
        amq.queue(ping.identity).publish(serializer.dump(Advertise.new))
      end
    end
    
    # forward request coming from agent
    def handle_request(request)
      if @security.authorize_request(request)
        result = Result.new(request.token, request.from, nil, mapper.identity)
        intm_handler = lambda do |res|
          result.results = res
          forward_response(result, request.persistent)
        end
        ok = mapper.send_request(request, :intermediate_handler => intm_handler) do |res|
          result.results = res
          forward_response(result, request.persistent)
        end
        if ok == false
          forward_response(result, request.persistent)
        end
      else
        Nanite::Log.warning("request #{request.inspect} not authorized")
      end
    end
    
    # forward response back to agent that originally made the request
    def forward_response(res, persistent)
      amq.queue(res.to).publish(serializer.dump(res), :persistent => persistent)
    end
    
    # returns least loaded nanite that provides given service
    def least_loaded(service, tags=[])
      candidates = nanites_providing(service,tags)
      return [] if candidates.empty?

      [candidates.min { |a,b| a[1][:status] <=> b[1][:status] }]
    end

    # returns all nanites that provide given service
    def all(service, tags=[])
      nanites_providing(service,tags)
    end

    # returns a random nanite
    def random(service, tags=[])
      candidates = nanites_providing(service,tags)
      return [] if candidates.empty?

      [candidates[rand(candidates.size)]]
    end

    # selects next nanite that provides given service
    # using round robin rotation
    def rr(service, tags=[])
      @last ||= {}
      @last[service] ||= 0
      candidates = nanites_providing(service,tags)
      return [] if candidates.empty?
      @last[service] = 0 if @last[service] >= candidates.size
      candidate = candidates[@last[service]]
      @last[service] += 1
      [candidate]
    end

    # returns all nanites that provide the given service
    def nanites_providing(service, *tags)
      nanites.nanites_for(service, *tags)
    end

    def setup_queues
      setup_heartbeat_queue
      setup_registration_queue
      setup_request_queue
    end

    def setup_heartbeat_queue
      handler = lambda do |ping|
        begin
          ping = serializer.load(ping)
          Nanite::Log.debug("got heartbeat from #{ping.identity}") if ping.respond_to?(:identity)
          handle_ping(ping)
        rescue Exception => e
          Nanite::Log.error("Error handling heartbeat: #{e.message}")
        end
      end
      hb_fanout = amq.fanout('heartbeat', :durable => true)
      if @redis
        amq.queue("heartbeat").bind(hb_fanout).subscribe &handler
      else
        amq.queue("heartbeat-#{identity}", :exclusive => true).bind(hb_fanout).subscribe &handler
      end
    end

    def setup_registration_queue
      handler = lambda do |msg|
        begin
          msg = serializer.load(msg)
          Nanite::Log.debug("got registration from #{msg.identity}")
          register(msg)
        rescue Exception => e
          Nanite::Log.error("Error handling registration: #{e.message}")
        end
      end
      reg_fanout = amq.fanout('registration', :durable => true)
      if @redis
        amq.queue("registration").bind(reg_fanout).subscribe &handler
      else
        amq.queue("registration-#{identity}", :exclusive => true).bind(reg_fanout).subscribe &handler
      end
    end
    
    def setup_request_queue
      handler = lambda do |msg|
        begin
          msg = serializer.load(msg)
          Nanite::Log.debug("got request from #{msg.from} of type #{msg.type}")
          handle_request(msg)
        rescue Exception => e
          Nanite::Log.error("Error handling request: #{e.message}")
        end
      end
      req_fanout = amq.fanout('request', :durable => true)
      if @redis
        amq.queue("request").bind(req_fanout).subscribe &handler
      else
        amq.queue("request-#{identity}", :exclusive => true).bind(req_fanout).subscribe &handler
      end
    end
  end
end
