require 'securerandom'
require 'urbanterror'
require 'yaml'

module Marion
  # Yey, let's share some servers via IRC
  #
  # This crappy code will allow you to share servers via an IRC bot. The servers are in the "conf/ServerSharing.yaml"
  # containig server ID, IP, port, rcon, state and current request settings.
  #
  # There multiple server states :
  #    - free     : The server is available for sharing
  #    - reserved : The server is reserved after someone do !gimmeaserver, so we're sure that the server wont be
  #                 given to someone else. The guy have 5 mins to configure via commands send in private to the bot
  #    - using    : The server is now configured with user's settings and we just gave him the /connect, he can now
  #                 connect to the server and enjoy it for 90 mins ;)
  #    - blocking : An admin decided to block this server (for maintenance or some private event) but the server was 
  #                 already in the using state with players inside, so we don't cut their game and for for it to end
  #                 to block the server. When the server will be released, it will be in blocked state instead of free
  #    - blocked  : An admin decided to block this server (for maintenance or some private event. The server isn't available
  class ServerSharing
    include Cinch::Plugin

    match 'gimmeaserver', method: :gimmeaserver

    # Admin stuff
    match 'status', method: :manage_status
    match 'reload', method: :manage_reload
    match /block ([a-zA-Z0-9]+)/, method: :manage_block
    match /unblock ([a-zA-Z0-9]+)/, method: :manage_unblock
    match /reset ([a-zA-Z0-9]+)\s?([a-f0-9]*)/, method: :manage_reset

    # User stuff for managing server and command
    match /^config (\S+)/, method: :set_config, use_prefix: false
    match /^map (\S+)/, method: :set_map, use_prefix: false
    match /^nextmap (\S+)/, method: :set_nextmap, use_prefix: false
    match /^password (\S+)/, method: :set_password, use_prefix: false
    match /^rcon ([a-zA-Z0-9]+)\s?([a-zA-Z0-9]*)/, method: :rcon, use_prefix: false
    match 'status', method: :request_status, use_prefix: false
    match 'cancel', method: :request_cancel, use_prefix: false
    match 'ready', method: :request_ready, use_prefix: false
    match 'finish', method: :request_finish, use_prefix: false

    timer 60, method: :check_expiry_request
    timer 60, method: :check_expiry_servers
    timer 120, method: :check_expiry_empty

    # Let's load the config !
    def initialize(bot)
      super # But before let cinch init the plugin :D

      @servers  = YAML.load_file(ROOT_DIR + '/conf/ServerSharing.yaml')
      @settings = YAML.load_file(ROOT_DIR + '/conf/ServerSharing.settings.yaml')
    end

    ### Commands ###

    # Ask for a server
    def gimmeaserver(m)
      # Don't accept request from non authed guys
      unless m.user.authed?
        m.reply "Sorry, but you need to be authed with Q in order to use this service", true
        m.user.refresh
        return
      end

      # Don't give servers between 3:20 and 5:20 because all server restart at 5:10. Even if there are players
      unless Time::now.strftime("%H%I").to_i < 320 || Time::now.strftime("%H%I").to_i > 520
        m.reply "Sorry. But there no server sharing until 5:20 am #{Time::now.dst?? "CEST": "CET"}", true
        return
      end

      # Reject request from banned guys
      if @settings['bans'].include? m.user.authname
        m.reply @settings['bans_messages'].sample, true
        return
      end

      # Reject request if he already have a request
      if already_have_a_request? m.user.authname
        m.reply "You already have a request. Look at your private messages ;)", true
        return
      end

      # Reject request if he already have a server
      if already_have_a_server? m.user.authname
        m.reply "You already have a server!", true
        return
      end

      # Check if there a free server and give it to the guy
      synchronize(:ServerSharing) do
        selected_server = false

        @servers.each do |id, server|
          if server['state'] == 'free'
            selected_server = id

            # Well, that's a bit silly if you give a server down :(
            sv = UrbanTerror::Server.new server['ip'], server['port']
            sv.update_status rescue selected_server = false

            break if selected_server
          end
        end

        # Poor guy, we have no servers for him
        unless selected_server
          m.reply "Sorry, but there's no server available :(", true
          return
        end

        # give the server and save it!
        @servers[selected_server]['state'] = 'reserved'
        @servers[selected_server]['requester'] = m.user.authname
        @servers[selected_server]['request_time'] = Time::now().to_i

        save_servers_state
      end

      m.reply "Hey #{m.user.nick} ! A server is available for you. Let's see the details in private ;)"

      m.user.send 'Let\'s go! Give me the configuration and the map. You can also set the nextmap and the password. Send one message per setting.'
      m.user.send 'For example : "config ts" - "map ut4_turnpike" and optionaly: "password FooBar" - "nextmap ut4_turnpike"'
      m.user.send 'When you\'re okay, write "ready" (By doing this, you agree the terms of service). If you change your mind, write cancel.'
      m.user.send "#{Format(:red,'WARNING')} : ONLY AUTHED PLAYERS will be able to connect and play on the servers."
    end

    ## Commands for managing ##

    # Print a list of all servers with their respective status
    def manage_status(m)
      return unless is_admin m.user.authname

      @servers.each do |server_id, server|
        server_is_up = true

        sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
        sv.update_status rescue server_is_up = false

        if server_is_up
          if server['state'] == 'free' || server['state'] == 'blocked'
            m.reply "Server : #{server_id} (#{server['ip']}:#{server['port']}) #{Format(:green,server['state'])}"
          elsif server['state'] == 'reserved'
            m.reply "Server : #{server_id} (#{server['ip']}:#{server['port']}) #{Format(:yellow,server['state'])} by #{server['requester']}"
          else
            m.reply "Server : #{server_id} (#{server['ip']}:#{server['port']}) #{Format(:red,server['state'])} by #{server['requester']} - #{time_remaining_for server_id}mins remaining [ #{sv.players.length} Players - #{sv.settings['mapname']} ]"
          end
        else
          m.reply "#{Format(:red,"Server #{server_id} is down....")} :< Server state is #{server['state']}"
        end
      end
    end

    # Reload servers sharing config (bans, maps, cfg...)
    def manage_reload(m)
      return unless is_admin m.user.authname

      synchronize(:SavingServersState) do
        @settings = YAML.load_file(ROOT_DIR + '/conf/ServerSharing.settings.yaml')    
      end

      m.reply "Configuration files reloaded"
    end

    # Allow blocking servers
    # The server wont be free for all ppl doing !gimmeaserver
    def manage_block(m, server_id)
      return unless is_admin m.user.authname

      if @servers[server_id]['state'] == 'using'
        @servers[server_id]['state'] = 'blocking'

        m.reply "Server #{server_id} will be blocked at match end."
      else
        clean_request server_id
        @servers[server_id]['state'] = 'blocked'

        m.reply "Server #{server_id} is now blocked."
      end
    end

    # Release blocked servers
    def manage_unblock(m, server_id)
      return unless is_admin m.user.authname

      if @servers[server_id]['state'] == 'blocking'
        @servers[server_id]['state'] = 'using'

        m.reply "Server #{server_id} is now unblocked."
      elsif  @servers[server_id]['state'] == 'blocked'
        @servers[server_id]['state'] = 'free'

        m.reply "Server #{server_id} is now free."
      end
    end

    # Reset a server. The server will be considered as free after that
    # To avoid errors, if there players on the server, a confirmation code will be asked
    def manage_reset(m, server_id, reset_token=nil)
      return unless is_admin m.user.authname

      server_is_up = true

      sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
      sv.update_status rescue server_is_up = false

      if server_is_up
        if sv.players.length >= 1 
          # Players on the server, let's ask to the admin if he's sure to reset this server
          if reset_token.nil? || @servers[server_id]['reset_token'] == -1 || @servers[server_id]['reset_token'] != reset_token
            @servers[server_id]['reset_token'] = SecureRandom.hex 5

            m.reply "Server #{server_id} is not empty (#{sv.players.length} players). Please confirm with !reset #{server_id} #{@servers[server_id]['reset_token']}"
          elsif !reset_token.nil? && @servers[server_id]['reset_token'] != -1 && @servers[server_id]['reset_token'] == reset_token
            # Admin is sure. let's reset the server!
            clean_request server_id
            reset_server server_id

            m.reply "Server reseted!"
          end

        else 
          # Nobody inside, we can reset it without risk
          clean_request server_id
          reset_server server_id

          m.reply "Server reseted!"
        end
      else
        # Huho problems :<
        m.reply "Server is down. No action taken"
      end
    end

    ## Commands for configuring the server! ##

    # Config step : Check if the conf is available and set it
    def set_config(m, config_file)
      return if m.channel?
      return unless already_have_a_request? m.user.authname

      server_id = already_have_a_request? m.user.authname

      unless @settings['configurations_availables'].has_key? config_file
        m.reply 'This configuration does not exist or isn\'t available for now.'
        return
      end

      @servers[server_id]['config'] = config_file
      save_servers_state

      m.reply "Okay! Config will be: #{config_file}"
    end

    # Config step : Check if the map is available and set it as first map
    def set_map(m, map)
      return if m.channel?
      return unless already_have_a_request? m.user.authname

      server_id = already_have_a_request? m.user.authname

      unless @settings['maps_availables'].has_key? map
        m.reply 'This map does not exist or isn\'t available for now.'
        return
      end

      @servers[server_id]['map'] = @settings['maps_availables'][map]
      save_servers_state
    
      m.reply "Okay! Starting map will be: #{@settings['maps_availables'][map]}"
    end

    # Config step : Check if map is available and setit as nextmap
    def set_nextmap(m, map)
      return if m.channel?
      return unless already_have_a_request? m.user.authname

      server_id = already_have_a_request? m.user.authname

      unless @settings['maps_availables'].has_key? map
        m.reply 'This map does not exist or isn\'t available for now.'
        return
      end
      
      @servers[server_id]['nextmap'] = @settings['maps_availables'][map]
      save_servers_state

      m.reply "Okay! Nextmap map will be: #{@settings['maps_availables'][map]}"
    end

    # Config step : Set server password
    def set_password(m, password)
      return if m.channel?
      return unless already_have_a_request? m.user.authname

      server_id = already_have_a_request? m.user.authname
      password = password[/[a-zA-Z0-9]+/]

      unless password.length >= 4
        m.reply 'Please choose a password with 4 or more charracters'
        return
      end

      @servers[server_id]['password'] = password
      save_servers_state

      m.reply "Okay! Password will be: #{password}"
    end

    # Mini rcon system, alloging the user to control some aspect of the server during the game
    # like the current map, the nextmap and the config
    def rcon(m, command, arg = nil)
      return if m.channel?
      return unless already_have_a_server? m.user.authname

      server_id = already_have_a_server? m.user.authname

      case command
      # He want to change the map, check if the map is avaiable and set it
      when 'map'
        unless @settings['maps_availables'].has_key? arg
          m.reply 'This map does not exist or isn\'t available for now.'
          return
        end
        
        m.reply "Okay! Changing map for #{@settings['maps_availables'][arg]}"
        sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
        sv.rcon "map #{@settings['maps_availables'][arg]}"

      when 'nextmap'
      # He want to change the nextmap, check if the map is avaiable and set it
        unless @settings['maps_availables'].has_key? arg
          m.reply 'This map does not exist or isn\'t available for now.'
          return
        end
        
        m.reply "Okay! Changing nextmapmap for #{@settings['maps_availables'][arg]}"
        sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
        sv.rcon "set g_nextmap #{@settings['maps_availables'][arg]}"

      when 'conf'
      # He want to change the con, check if the conf is avaiable and set it
        unless @settings['configurations_availables'].has_key? arg
          m.reply 'This configuration does not exist or isn\'t available for now.'
          return
        end

        m.reply "Okay! Changing config for #{arg}, wait a second please.... the server will reload."
        sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
        sv.rcon "exec #{@settings['configurations_availables'][arg]}", true
        sv.rcon "reload"

      when 'veto'
      # He want to veto the current vote
        m.reply "Vote canceled."
        sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
        sv.rcon "veto"

      else
        m.reply "Only map, conf, veto are allowed"
      end    
    end

    # Magic status gommand, will give current chosen settings if the game isn't started
    # or give the /connect + remaining time again if the game was started
    def request_status(m)
      return if m.channel?

      if already_have_a_request? m.user.authname
        server_id = already_have_a_request? m.user.authname

        if @servers[server_id]['config'] == -1 && @servers[server_id]['map'] == -1
          m.reply "No parameters defined"
        else
          config = @servers[server_id]['config'] == -1 ?  "No configuration defined | " : "Configuration: #{@servers[server_id]['config']} | "
          map = @servers[server_id]['map'] == -1 ?  "No map defined | " : "Map: #{@servers[server_id]['map']} | "
          nextmap = @servers[server_id]['nextmap'] == -1 ?  "No nextmap defined | " : "Nextmap: #{@servers[server_id]['nextmap']} | "
          settings = @servers[server_id]['password'] == -1 ?  "Password will be random | " : "Password: #{@servers[server_id]['password']} | "

          m.reply config + map + nextmap + settings
        end

      elsif already_have_a_server? m.user.authname
        server_id = already_have_a_server? m.user.authname
        minutes_remaining = time_remaining_for server_id

        m.reply "Your server is here => /connect #{@servers[server_id]['ip']}:#{@servers[server_id]['port']};password #{@servers[server_id]['password']} -- Referee password is #{@servers[server_id]['refpassword']}"
        m.reply "Time remaining #{minutes_remaining} mins. When your match is over, don't forget to tell me finish."

      else
        m.reply "You have no servers :(" 
      end
        
    end

    # This guy changed his mind, and donn't wand a server anymore, just
    # clean the request
    def request_cancel(m)
      return if m.channel?
      return unless already_have_a_request? m.user.authname

      server_id = already_have_a_request? m.user.authname
      clean_request server_id

      m.reply "Request canceled. See you soon!"
    end

    # Okay, the user s ready to go! Check if all necessary settings are set (1st map + conf)
    # Chose a random password if they didn't asked for one, and configure the server
    def request_ready(m)
      return if m.channel?

      return unless already_have_a_request? m.user.authname
      server_id = already_have_a_request? m.user.authname

      # Make sure that, if the guy do ready twice or more, it will not fuckup everything
      synchronize(:ServerSharingInitServ) do
        return unless already_have_a_request? m.user.authname
        server_id = already_have_a_request? m.user.authname

        # Did he chose a conf ?
        if @servers[server_id]['config'] == -1
          m.reply "No configuration defined...."
          return
        end

        # Did he chose a map ?
        if @servers[server_id]['map'] == -1
          m.reply "No map defined...."
          return
        end

        # Generate a password if none provided!
        if @servers[server_id]['password'] == -1
          @servers[server_id]['password'] = SecureRandom.hex 3
          m.reply "Password will be #{ @servers[server_id]['password'] }"
        end

        # Generate a referee password
        @servers[server_id]['refpassword'] = SecureRandom.hex 3
        m.reply "Referee password will be #{ @servers[server_id]['refpassword'] }"

        # Update server state
        @servers[server_id]['state'] = 'using'
        @servers[server_id]['request_time'] = Time::now.to_i
        save_servers_state
      end

      # "Allons y! Let's go" Configure the server, and give him the /connect
      m.reply "Configuring the server...."
      sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']

      sv.rcon 'set sv_hostname "^3|GH| ^4Server ^7For ^1All !^7 - ^1BUSY "', true
      sv.rcon "set g_password #{@servers[server_id]['password']}", true
      sv.rcon "set g_refpass #{@servers[server_id]['refpassword']}", true
      sv.rcon "set g_nextmap #{@servers[server_id]['nextmap']}", true if @servers[server_id]['nextmap'] != -1
      sv.rcon "set g_log \"logs/server4all/#{Time.now.strftime('%Y-%m-%d_%H-%M')}_#{m.user.authname}.log\"", true

      sv.rcon "exec #{@settings['configurations_availables'][@servers[server_id]['config']]}", true
      sv.rcon "map #{@servers[server_id]['map']}", true

      m.reply "The server is ready ! It's yours during 90 mins => /connect #{@servers[server_id]['ip']}:#{@servers[server_id]['port']};password #{@servers[server_id]['password']}"
      m.reply 'If you want to know the time remaining, write status. When your match is over, write finish.'

    end

    # Good guy telling us that the game is over ;)
    # Let's cleanup the server and make if free for someone else!
    def request_finish(m)
      return if m.channel?

      synchronize(:ServerSharingFinish) do
        return unless already_have_a_server? m.user.authname

         m.reply "Okay ;), See you soon!"
        server_id = already_have_a_server? m.user.authname
        clean_request server_id
        reset_server server_id
      end
    end

    ### Timers ###
    # Timer : As all !gimmeaserver 'reserve' a server for being sure that nobody elese will take it, we need to 
    # remove old (requested more than 5 mins ago) uncompleted request to make the server free again
    def check_expiry_request
      debug 'Checking expired requests'

      synchronize(:ServerSharingExpiryChecks) do
        @servers.each do |server_id, server|
          if server['state'] == 'reserved' && server['request_time'] + 300 < Time::now().to_i
            clean_request server_id
          end
        end

        save_servers_state
      end
    end

    # Timer : check used servers remaining time, displays it on the servers from time to time
    # and shut the game when there's no time left
    def check_expiry_servers
      debug 'Checking expired servers'

      synchronize(:ServerSharingExpiryChecks) do
        @servers.each do |server_id, server|
          if (server['state'] == 'using' || server['state'] == 'blocking') && server['request_time'] + @settings['duration'] * 60 < Time::now().to_i
            clean_request server_id
            reset_server server_id

          elsif server['state'] == 'using' || server['state'] == 'blocking'
            minutes_remaining = time_remaining_for server_id

            case minutes_remaining
              when 59..60 then send_remaining_time server_id, minutes_remaining
              when 39..40 then send_remaining_time server_id, minutes_remaining
              when 29..30 then send_remaining_time server_id, minutes_remaining
              when 19..20 then send_remaining_time server_id, minutes_remaining
              when 14..15 then send_remaining_time server_id, minutes_remaining
              when 0..10 then send_remaining_time server_id, minutes_remaining, true                        
            end
          end
        end

        save_servers_state
      end

    end

    # Timer : Check used servers to see if there empty, meaning that the game ended and the guy didn't told us :(
    # If the server is empty and have been requested more than 5 mins ago, the server will be freed
    def check_expiry_empty
      debug 'Checking empty servers'

      synchronize(:ServerSharingExpiryChecks) do
        @servers.each do |server_id, server|
          if (server['state'] == 'using' || server['state'] == 'blocking') && server['request_time'] + 300 < Time::now().to_i

            begin
              sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
              sv.update_status

              if sv.players.length == 0
                clean_request server_id
                reset_server server_id
              end
            rescue
              debug "Can't get info from #{server_id}.... :<"
            end
          end
        end
      end
    end

    ### Random Stuff ###

    # Check if the given q account already have a request (server reserved, but not configured)
    # Return true if he have one, false if not
    def already_have_a_request?(qaccount)
      return if qaccount == nil

      @servers.each do |server_id, server|
        return server_id if server['requester'] == qaccount && server['state'] == 'reserved'
      end

      return false
    end

    # Check if the given q account already have a server
    # Return true if yes, false if not
    def already_have_a_server?(qaccount)
      return if qaccount == nil

      @servers.each do |server_id, server|
        return server_id if server['requester'] == qaccount && ( server['state'] == 'using' || server['state'] == 'blocking' )
      end

      return false
    end

    # Clean the request info.
    # If the server is in "blocking" state, it will be switeched as blocked, allowing to block servers
    # gracefully even if the server is busy and without cutting down the game
    def clean_request(server_id)
      @servers[server_id]['state'] = 'blocked' if @servers[server_id]['state'] == 'blocking'

      @servers[server_id]['state'] = 'free' unless @servers[server_id]['state'] == 'blocked'
      @servers[server_id]['requester'] = -1
      @servers[server_id]['request_time'] = -1
      @servers[server_id]['config'] = -1
      @servers[server_id]['map'] = -1
      @servers[server_id]['nextmap'] = -1
      @servers[server_id]['refpassword'] = -1
      @servers[server_id]['password'] = -1
      @servers[server_id]['reset_token'] = -1
    end

    # Reset the server by execig the default config
    def reset_server(server_id)
      sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
      sv.rcon 'exec event.cfg'
    end

    # Calculate the remaining time for a giver server
    def time_remaining_for(server_id)
      seconds_remaining = @servers[server_id]['request_time'] + @settings['duration']*60 - Time::now().to_i
      (seconds_remaining - (seconds_remaining % 60)) /60
    end

    # Display the remaining time on the server via server message or bigtext
    def send_remaining_time(server_id, time_remaining, bigtext = false)
      sv = UrbanTerror::Server.new @servers[server_id]['ip'], @servers[server_id]['port'], @servers[server_id]['rcon']
      if bigtext
        sv.rcon "bigtext \"^6 #{time_remaining}  minutes ^3remaining\""
      else
        sv.rcon "^6 #{time_remaining}  minutes ^3remaining"
      end
    end

    # Save server state
    def save_servers_state
      synchronize(:SavingServersState) do
        File.open(ROOT_DIR + '/conf/ServerSharing.yaml', 'w+') {|f| f.write(@servers.to_yaml)}
      end
    end

    # Check if the given q account is in the admin list
    # return true if this is and admin account, false if not
    def is_admin(qaccount)
      return @settings['admins'].include? qaccount
    end

    # Transform q3 color code in IRC color code
    def q3colors_2_irccolors(str)
      str.gsub!(/\^1/,"\x0304")
      str.gsub!(/\^2/,"\x0309")
      str.gsub!(/\^3/,"\x0307")
      str.gsub!(/\^4/,"\x0302")
      str.gsub!(/\^5/,"\x0310")
      str.gsub!(/\^6/,"\x0313")
      str.gsub!(/\^7/,"\x0301")
      str.gsub(/\^([0-9])/, '')
    end
  end
end
