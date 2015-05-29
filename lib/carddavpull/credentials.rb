require 'mail'

module CardDavPull

  class Credentials
    
    DEFAULTS = {
      username: nil,
      password: nil,
      host: nil
    }
    
    attr :username, :password, :host
    
    def initialize(options = {})
      options = DEFAULTS.merge(options)
      
      @username = options[:username]
      @password = options[:password]
      @initial_host = options[:host]
      
      @host = @initial_host.nil? || @initial_host.empty? ? domain_from_username : @initial_host
    end
    
    def domain_from_username
      Mail::Address.new(@username).domain
    end
    
  end

end