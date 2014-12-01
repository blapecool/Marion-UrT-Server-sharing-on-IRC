# encoding: utf-8

$LOAD_PATH.push File.expand_path(File.dirname(__FILE__) + '/lib/')
ROOT_DIR = File.expand_path(File.dirname(__FILE__))

require 'json'
require 'cinch'
require 'urbanterror'
require 'cinch/plugins/identify'
require 'marion/ServerSharing'

bot = Cinch::Bot.new do
  configure do |c|
  c.server           = 'irc.quakenet.org'

  c.nick             = 'Marion'
  c.realname         = 'Marion'
  c.username         = 'Marion'
              
  c.channels         = ['#My_Channel', '#yey', '#my_secret_channel']
  c.delay_joins      = :identified
  c.modes            = ['+x']
              
  c.plugins.plugins  = [Cinch::Plugins::Identify, Marion::ServerSharing]

  c.plugins.options[Cinch::Plugins::Identify] = {
    username:   "USERNAME",
    password:   "P@$$W0rD",
    type:       :secure_quakenet,
  }

  end
end

bot.start
