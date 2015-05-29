require 'resolv'
require 'uri'
require 'net/https'
require 'nokogiri'
require 'vcard'

module CardDavPull
  
  class Client
  
    SERVICE_LABEL = '_carddav._tcp'
    SERVICE_LABEL_TLS = '_carddavs._tcp'

    WELL_KNOWN_URI = '/.well-known/carddav/'
  
    DEFAULTS = {
      allow_insecure_connections: false
    }
  
    attr :debug
      
    attr :credentials, :allow_insecure_connections
  
    attr :protocol, :host, :port, :fqdn_found_via
  
    attr :initial_context_path
    attr :principal_url
    attr :addressbook_home_set_url
  
    def initialize(credentials, options = {})
      @credentials = credentials
      
      options = DEFAULTS.merge(options)
      @allow_insecure_connections = options[:allow_insecure_connections]
      
      @connections = {}
      
      @debug = true
    end

    def base_url
      @addressbook_home_set_url ||= bootstrap
    end
    
    def username
      @credentials.username
    end
    
    def password
      @credentials.password
    end
    
    def initial_host
      @credentials.host
    end
    
    def pull_all
      # TODO: Do we always need to append "card/" to the url? This is for iCloud ...
      addressbook = base_url.merge('card/')
    
      # Collect the URL of each vCard
      cards = get_all_card_urls(addressbook)
    
      # Retrieve all cards
      retrieve_cards(addressbook, cards)
    end
  
    def get_all_card_urls(addressbook)
      # Collect the URL of each vCard
      xml =
        %Q(<A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
             <A:prop>
               <A:resourcetype/>
               <C:address-data/>
             </A:prop>
           </A:propfind>)
      document = propfind(addressbook, { "Depth" => 1 }, xml)
    
      # There are multiple namespaces in the document that cause problems with the
      # CSS selector
      document.remove_namespaces!
    
      cards = []
      document.css('multistatus response').each do |card|
        # Skip the collection parent
        next unless card.at_css('resourcetype addressbook').nil?
      
        cards << card.at_css('href').text
      end
    
      cards
    end
  
    def retrieve_cards(addressbook, cards)
      # Retrievel all cards as specified by their urls in one single multi-get
      xml =
        %Q(<C:addressbook-multiget xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
             <A:prop>
               <C:address-data/>
             </A:prop>
             #{cards.map { |url| '<A:href>' << url << '</A:href>' }.join("\n             ") }
           </C:addressbook-multiget>)
         
      document = report(addressbook, { "Depth" => 1 }, xml)
    
      # There are multiple namespaces in the document that cause problems with the
      # CSS selector
      document.remove_namespaces!
    
      # Create the vcard objects
      # TODO: Maybe use the gem VCardigan instead, since it supports VCard 4.0?
      cards = document.css('multistatus response propstat prop address-data')
        .map { |node| node.text }
        .reject { |text| !text }
        .map { |text| Vcard::Vcard.decode(text).first }
    
      cards
    end
  
    private
    
    def bootstrap
      determine_fqdn_and_port
      determine_initial_context_path
      determine_principal_url
      determine_addressbook_home_set_url
    end
    
    def service_resources
      resources = {
        https: "#{SERVICE_LABEL_TLS}.#{initial_host}",
        http: "#{SERVICE_LABEL}.#{initial_host}"
      }
      
      resources.delete(:http) unless @allow_insecure_connections
      
      resources
    end
  
    def determine_fqdn_and_port
  
      # Steps/Priorities to locate a FQDN and port:
      #
      #   1: Via DNS (SRV lookup) and well-known URI
      #   2: Via domain extracted from username and well-known URI
  
      resources = service_resources

      host = nil
      protocol = nil
    
      resources.each do |p, name|
        hosts = fetch_dns_resources(name, Resolv::DNS::Resource::IN::SRV)
        next if hosts.empty?
      
        host = hosts[0]
        protocol = p
        break # if something has been found
      end

      if host.nil?
        # Use a "simple heuristic" if no SRV record could be found
        @protocol = :https
        @host = initial_host
        @port = 443
        @fqdn_found_via = :heuristic
      
        # TODO: If @allow_insecure_connections is true then there should be a test
        #       if there is something at the secure port and a fallback to the
        #       non-secure port.
      else
        # TODO: If there is more than one host returned, there should be a check
        #       if a host is available and, if not, fallback to the next one
        @protocol = protocol
        @host = host.target
        @port = host.port
        @fqdn_found_via = :srv
      end
    
      puts "Host = #{@host}, Port = #{@port}" if @debug
    end
  
    def determine_initial_context_path
      # Try to get a matching TXT record from the domain, if none exists use .well-known URI
      # TODO: Hit the TXT path, on error use .well-known URI
      # TODO: Test .well-known URI
  
      @initial_context_path = nil

      if @fqdn_found_via == :srv
        resources = service_resources
        records = fetch_dns_resources(resources[@protocol], Resolv::DNS::Resource::IN::TXT)
    
        unless records.empty?
          data = records.map do |r1|
            r1.data.split(';')
              .map { |r2| r2.strip }
              .map { |r2| r2.split('=') }
          end
  
          data = Hash[*data.flatten]
          @initial_context_path = data['path'] if !data['path'].nil? && http_path_exists(data['path'])
        end
      end
  
      @initial_context_path ||= WELL_KNOWN_URI
    end
    
    def http_path_exists(path)
      # TODO: Really check this
      true
    end
  
    def determine_principal_url
      # Ask the server via PROPFIND to return the current-user-principal URI
  
      xml =
        %Q(<A:propfind xmlns:A="DAV:">
             <A:prop>
               <A:current-user-principal/>
               <A:principal-URL/>
             </A:prop>
           </A:propfind>)

      document = propfind(initial_url, { "Depth" => 1 }, xml)
  
      # First try: Look for current-user-principal
      element = document.at_css('current-user-principal href')
  
      # Second try: Look for principal-URL
      element = document.at_css('principal-URL href') if element.nil?
  
      raise 'Could not determine principal url.' if element.nil?
  
      @principal_url = url_with_path(element.text)
    end
  
    def determine_addressbook_home_set_url
      xml =
        %Q(<A:propfind xmlns:A="DAV:">
             <A:prop>
               <addressbook-home-set xmlns="urn:ietf:params:xml:ns:carddav"/>
             </A:prop>
           </A:propfind>)

      document = propfind(@principal_url, { "Depth" => 0 }, xml)
  
      # There are multiple namespaces in the document that cause problems with the
      # CSS selector
      document.remove_namespaces!
  
      element = document.at_css('addressbook-home-set href')
      raise 'Could not determine addressbook home set url.' if element.nil?
  
      @addressbook_home_set_url = @principal_url.merge(element.text)
    end
  
    def url_with_path(path)
      URI.join("#{@protocol}://#{@host}:#{@port}", path)
    end

    def initial_url
      url_with_path(@initial_context_path)
    end
  
    def fetch_dns_resources(name, type)
      @resolver ||= Resolv::DNS.new

      records = @resolver.getresources(name, type)

      # DNS-based load balancing using "priority and ""weight"
      # TODO: Actually test if the behavior is correct.
      if type == Resolv::DNS::Resource::IN::SRV
        records.sort! { |a, b| (a.priority == b.priority) ? a.weight - b.weight : a.priority - b.priority }
      end
  
      records
    end
    
    def get(uri, headers = {})
      http_fetch(Net::HTTP::Get, uri, headers)
    end

    def propfind(uri, headers = {}, xml)
      http_fetch(Net::HTTP::Propfind, uri, headers, xml)
    end

    def report(uri, headers = {}, xml)
      http_fetch(Net::HTTP::Report, uri, headers, xml)
    end
  
    def http_fetch(req_type, uri, headers = {}, data = nil)
      
      puts "HTTP Fetch from #{uri}" if @debug
    
      # Keep the connection alive since we're probably sending all requests to
      # it anyway and we'll gain some speed by not reconnecting every time.
      unless (host = @connections["#{uri.host}:#{uri.port}"])
        host = Net::HTTP.new(uri.host, uri.port)
        host.use_ssl = (uri.scheme == 'https')
        host.verify_mode = OpenSSL::SSL::VERIFY_PEER

        # Enable debugging, if wished
        host.set_debug_output($stdout) if @debug

        # If we don't call +start+ ourselves, host.request will, but it will do
        # it in a block that will call +finish+ when exiting request, closing
        # the connection even though we're specifying keep-alive.
        host.start

        @connections["#{uri.host}:#{uri.port}"] = host
      end

      # Prepare the request
      request = req_type.new(uri)
      request.basic_auth(username, password)
      request['Connection'] = 'keep-alive'
      request['Content-Type'] = 'text/xml; charset="UTF-8"'

      # Pass along specified headers to the request
      headers.each { |k,v| request[k] = v }

      # Set request body data, if passed
      request.body = data if data

      # Do the actual request
      response = host.request(request)

      if @debug
        puts ''
        puts ''
        puts ''
        puts ''
        puts '====================================================================='
        puts ''
        puts response.body
      end
    
      # Parse the result
      Nokogiri::XML(response.body)
    end
    
  end
  
end