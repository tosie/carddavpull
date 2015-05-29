require "carddavpull/version"
require 'carddavpull/net_http_report'
require 'carddavpull/credentials'
require 'carddavpull/client'

module CardDavPull
  
  def self.all(username, password, host = nil)
    credentials = CardDavPull::Credentials.new(username: username, password: password, host: host)
    client = CardDavPull::Client.new(credentials)
    
    client.pull_all
  end
  
end