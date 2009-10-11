require 'rack/request'
require 'rack/utils'

require 'openid'
require 'openid/consumer'
require 'openid/extensions/sreg'
require 'openid/extensions/ax'

module Rack
  class OpenID
    def self.build_header(params = {})
      value = 'OpenID '
      value += params.map { |k, v|
        if v.is_a?(Array)
          "#{k}=\"#{v.join(',')}\""
        else
          "#{k}=\"#{v}\""
        end
      }.join(', ')
      value
    end

    def self.parse_header(str)
      params = {}
      if str =~ /^OpenID/
        str = str.gsub(/^OpenID /, '')
        str.split(', ').each { |e|
          k, *v = e.split('=')
          v = v.join('=')
          v.gsub!(/^\"/, '').gsub!(/\"$/, "")
          v = v.split(',')
          params[k] = v.length > 1 ? v : v.first
        }
      end
      params
    end

    class TimeoutResponse
      include ::OpenID::Consumer::Response
      STATUS = :failure
    end

    class MissingResponse
      include ::OpenID::Consumer::Response
      STATUS = :missing
    end

    HTTP_METHODS = %w(GET HEAD PUT POST DELETE OPTIONS)

    RESPONSE = "rack.openid.response".freeze
    AUTHENTICATE_HEADER = "WWW-Authenticate".freeze


    def initialize(app, store = nil)
      @app = app
      @store = store || default_store
      freeze
    end

    def call(env)
      req = Rack::Request.new(env)
      if env["REQUEST_METHOD"] == "GET" && req.GET["openid.mode"]
        complete_authentication(env)
      end

      status, headers, body = @app.call(env)

      if status.to_i == 401 && (qs = headers[AUTHENTICATE_HEADER])
        begin_authentication(env, qs)
      else
        [status, headers, body]
      end
    end

    private
      def begin_authentication(env, qs)
        req = Rack::Request.new(env)
        params = self.class.parse_header(qs)

        unless session = env["rack.session"]
          raise RuntimeError, "Rack::OpenID requires a session"
        end

        consumer = ::OpenID::Consumer.new(session, @store)
        identifier = params["identifier"]

        begin
          oidreq = consumer.begin(identifier)
          add_simple_registration_fields(oidreq, params)
          add_attribute_exchange_fields(oidreq, params)
          url = open_id_redirect_url(req, oidreq, params["trust_root"], params["return_to"], params["method"])
          return redirect_to(url)
        rescue ::OpenID::OpenIDError, Timeout::Error => e
          env[RESPONSE] = MissingResponse.new
          return @app.call(env)
        end
      end

      def complete_authentication(env)
        req = Rack::Request.new(env)

        unless session = env["rack.session"]
          raise RuntimeError, "Rack::OpenID requires a session"
        end

        oidresp = timeout_protection_from_identity_server {
          consumer = ::OpenID::Consumer.new(session, @store)
          consumer.complete(req.params, req.url)
        }

        env[RESPONSE] = oidresp

        if method = req.GET["_method"]
          method = method.upcase
          if HTTP_METHODS.include?(method)
            env["REQUEST_METHOD"] = method
          end
        end

        query_hash = env["rack.request.query_hash"]
        query_hash.delete("_method")
        query_hash.delete_if do |key, value|
          key =~ /^openid\./
        end

        env["QUERY_STRING"] = env["rack.request.query_string"] =
          Rack::Utils.build_query(env["rack.request.query_hash"])

        request_uri = env["PATH_INFO"]
        unless env["QUERY_STRING"] == ""
          request_uri << "?" + env["QUERY_STRING"]
        end
        env["REQUEST_URI"] = request_uri
      end

      def realm_url(req)
        url = req.scheme + "://"
        url << req.host

        if req.scheme == "https" && req.port != 443 ||
            req.scheme == "http" && req.port != 80
          url << ":#{req.port}"
        end

        url
      end

      def request_url(req)
        url = realm_url(req)
        url << req.script_name
        url << req.path_info
        url
      end

      def redirect_to(url)
        [303, {"Content-Type" => "text/html", "Location" => url}, []]
      end

      def open_id_redirect_url(req, oidreq, trust_root = nil, return_to = nil, method = nil)
        if return_to
          method ||= "get"
        else
          return_to = request_url(req)
          method ||= req.request_method
        end

        method = method.to_s.downcase
        oidreq.return_to_args['_method'] = method unless method == "get"
        oidreq.redirect_url(trust_root || realm_url(req), return_to || request_url(req))
      end

      URL_FIELD_SEPERATOR = "@@"
      URL_FIELD_SELECTOR = lambda { |field| field.to_s =~ %r{^https?://} }

      def add_simple_registration_fields(oidreq, fields)
        sregreq = ::OpenID::SReg::Request.new

        required = Array(fields['required']).reject(&URL_FIELD_SELECTOR)
        sregreq.request_fields(required, true) if required.any?

        optional = Array(fields['optional']).reject(&URL_FIELD_SELECTOR)
        sregreq.request_fields(optional, false) if optional.any?

        if policy_url = fields['policy_url']
          sregreq.policy_url = policy_url
        end

        oidreq.add_extension(sregreq)
      end

      def add_attribute_exchange_fields(oidreq, fields)
        axreq = ::OpenID::AX::FetchRequest.new

        required = Array(fields['required']).select(&URL_FIELD_SELECTOR)
        optional = Array(fields['optional']).select(&URL_FIELD_SELECTOR)
        
        (required + optional).each do |field| 
          field, field_alias = field.split(URL_FIELD_SEPERATOR)
          axreq.add(::OpenID::AX::AttrInfo.new(field, field_alias, true)) 
        end

        oidreq.add_extension(axreq)
      end

      def default_store
        require 'openid/store/memory'
        ::OpenID::Store::Memory.new
      end

      def timeout_protection_from_identity_server
        yield
      rescue Timeout::Error
        TimeoutResponse.new
      end
  end
end
