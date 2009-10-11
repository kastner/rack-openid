require 'test/unit'
require 'mocha'
require 'net/http'

require 'rack/mock'
require 'rack/session/pool'
require 'rack/openid'

log = Logger.new(STDOUT)
log.level = Logger::WARN
OpenID::Util.logger = log

class TestHeader < Test::Unit::TestCase
  def test_build_header
    assert_equal 'OpenID identity="http://example.com/"',
      Rack::OpenID.build_header(:identity => "http://example.com/")
    assert_equal 'OpenID identity="http://example.com/?foo=bar"',
      Rack::OpenID.build_header(:identity => "http://example.com/?foo=bar")
    assert_equal 'OpenID identity="http://example.com/", return_to="http://example.org/"',
      Rack::OpenID.build_header(:identity => "http://example.com/", :return_to => "http://example.org/")
    assert_equal 'OpenID identity="http://example.com/", required="nickname,email"',
      Rack::OpenID.build_header(:identity => "http://example.com/", :required => ["nickname", "email"])
  end

  def test_parse_header
    assert_equal({"identity" => "http://example.com/"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/"'))
    assert_equal({"identity" => "http://example.com/?foo=bar"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/?foo=bar"'))
    assert_equal({"identity" => "http://example.com/", "return_to" => "http://example.org/"},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/", return_to="http://example.org/"'))
    assert_equal({"identity" => "http://example.com/", "required" => ["nickname", "email"]},
      Rack::OpenID.parse_header('OpenID identity="http://example.com/", required="nickname,email"'))
  end
end

class TestOpenID < Test::Unit::TestCase
  RotsServer = 'http://localhost:9292'

  @server_started = false

  def self.start_server!
    return if @server_started

    pid = fork {
      STDIN.reopen "/dev/null"
      STDOUT.reopen "/dev/null", "a"
      STDERR.reopen "/dev/null", "a"

      exec "rackup test/openid_server.ru"
    }

    at_exit {
      Process.kill 9, pid
      Process.wait(pid)
    }

    begin
      uri = URI.parse(RotsServer)
      response = Net::HTTP.get_response(uri)
    rescue Errno::ECONNREFUSED
      sleep 0.5
      retry
    end

    @server_started = true
  end

  def setup
    self.class.start_server!
  end

  def test_with_get
    @app = app
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_post_method
    @app = app
    process('/', :method => 'POST')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'POST', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_custom_return_to
    @app = app(:return_to => 'http://example.org/complete')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/complete', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_post_method_custom_return_to
    @app = app(:return_to => 'http://example.org/complete')
    process('/', :method => 'POST')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/complete', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_custom_return_method
    @app = app(:method => 'put')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'PUT', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_simple_registration_fields
    @app = app(:required => ['nickname', 'email'], :optional => 'fullname')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_with_attribute_exchange
    @app = app(
      :required => ['http://axschema.org/namePerson/friendly', 'http://axschema.org/contact/email'],
      :optional => 'http://axschema.org/namePerson')
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 200, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'success', @response.body
  end

  def test_parameter_with_attribute_exchange
    @app = app(
    :required => ['http://axschema.org/namePerson/friendly', 'http://axschema.org/contact/email']
    )
    process('/', :method => 'GET')
    assert_parameter "openid.ax.type.ext1", "http://axschema.org/contact/email"
    assert_parameter "openid.ax.type.ext0", "http://axschema.org/namePerson/friendly"
  end
  
  def test_with_google_attribute_exchange
    @app = app(:required => 'http://axschema.org/contact/email@@email')
    process('/', :method => 'GET')
    assert_parameter "openid.ax.type.email", "http://axschema.org/contact/email"
  end

  def test_with_missing_id
    @app = app(:identifier => "#{RotsServer}/john.doe")
    process('/', :method => 'GET')
    follow_redirect!
    assert_equal 400, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'cancel', @response.body
  end

  def test_with_timeout
    @app = app(:identifier => RotsServer)
    process('/', :method => "GET")
    assert_equal 400, @response.status
    assert_equal 'GET', @response.headers['X-Method']
    assert_equal '/', @response.headers['X-Path']
    assert_equal 'missing', @response.body
  end

  private
    def app(options = {})
      options[:identifier] ||= "#{RotsServer}/john.doe?openid.success=true"

      app = lambda { |env|
        if resp = env[Rack::OpenID::RESPONSE]
          headers = {'X-Path' => env['PATH_INFO'], 'X-Method' => env['REQUEST_METHOD']}
          if resp.status == :success
            [200, headers, [resp.status.to_s]]
          else
            [400, headers, [resp.status.to_s]]
          end
        else
          [401, {Rack::OpenID::AUTHENTICATE_HEADER => Rack::OpenID.build_header(options)}, []]
        end
      }
      Rack::Session::Pool.new(Rack::OpenID.new(app))
    end

    def process(*args)
      env = Rack::MockRequest.env_for(*args)
      @response = Rack::MockResponse.new(*@app.call(env))
    end

    def follow_redirect!
      assert @response
      assert_equal 303, @response.status
      location = URI.parse(@response.headers['Location'])
      response = Net::HTTP.get_response(location)
      uri = URI(response['Location'])
      process("#{uri.path}?#{uri.query}")
    end

    def assert_parameter(key, value=nil, url=nil)
      headers = extract_parameters(url || @response.headers['Location'])
      assert headers.keys.include?(key), "#{key} not in #{headers.keys.join(", ")}"
      assert_equal value, URI.unescape(headers[key]) if value
    end
    
    def extract_parameters(url)
      url = URI.parse(url) unless url.is_a? URI
      Hash[*url.query.split(/[&=]/)]
    end
end
