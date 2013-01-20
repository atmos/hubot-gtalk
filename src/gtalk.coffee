{Robot, Adapter, EnterMessage, LeaveMessage, TextMessage} = require('hubot')

Xmpp    = require 'node-xmpp'

class Gtalkbot extends Adapter
  run: ->
    Xmpp.JID.prototype.from = -> @bare().toString()

    @name = @robot.name

    # Client Options
    @options =
      username: process.env.HUBOT_GTALK_USERNAME
      password: process.env.HUBOT_GTALK_PASSWORD
      acceptDomains: (entry.trim() for entry in (process.env.HUBOT_GTALK_WHITELIST_DOMAINS ? '').split(',') when entry.trim() != '')
      acceptUsers: (entry.trim() for entry in (process.env.HUBOT_GTALK_WHITELIST_USERS ? '').split(',') when entry.trim() != '')
      regexpTrans: process.env.HUBOT_GTALK_REGEXP_TRANSFORMATIONS
      host: 'talk.google.com'
      port: 5222
      keepaliveInterval: 15000 # ms interval to send query to gtalk server

    if not @options.username or not @options.password
      throw new Error('You need to set HUBOT_GTALK_USERNAME and HUBOT_GTALK_PASSWORD anv vars for gtalk to work')

    # Connect to gtalk servers
    @client = new Xmpp.Client
      reconnect: true
      jid: @options.username
      password: @options.password
      host: @options.host
      port: @options.port

    # Events
    @client.on 'online', => @online()
    @client.on 'stanza', (stanza) => @readStanza(stanza)
    @client.on 'error', (err) => @error(err)

  online: ->
    self = @

    @client.send new Xmpp.Element('presence')

    # He is alive!
    console.log @name + ' is online, talk.google.com!'

    roster_query = new Xmpp.Element('iq',
        type: 'get'
        id: (new Date).getTime()
      )
      .c('query', xmlns: 'jabber:iq:roster')

    self.emit "connected"

    # Check for buddy requests every so often
    @client.send roster_query
    setInterval =>
      @client.send roster_query
    , @options.keepaliveInterval

  readStanza: (stanza) ->
    # Useful for debugging
    # console.log stanza

    # Check for erros
    if stanza.attrs.type is 'error'
      console.error '[xmpp error] - ' + stanza
      return

    # Detect if message is an invitation
    if stanza.getChild('x') and stanza.getChild('x').getChild('invite')
      @handlePresence stanza
      return

    # Check for presence responses
    if stanza.is 'presence'
      @handlePresence stanza
      return

    # Check for message responses
    if stanza.is 'message' or stanza.attrs.type not in ['groupchat', 'direct', 'chat']
      @handleMessage stanza
      return

  handleMessage: (stanza) ->
    jid = new Xmpp.JID(stanza.attrs.from)

    if @isMe(jid)
      return

    if @ignoreUser(jid)
      console.log "Ignoring user message because of whitelist: #{stanza.attrs.from}"
      console.log "  Accepted Users: " + @options.acceptUsers.join(',')
      console.log "  Accepted Domains: " + @options.acceptDomains.join(',')
      return

    # ignore empty bodies (i.e., topic changes -- maybe watch these someday)
    body = stanza.getChild 'body'
    return unless body

    message = body.getText()

    # If we've configured some regexp transformations, apply them on the message
    if @options.regexpTrans?
      [reg, trans] = @options.regexpTrans.split("|")
      message = message.replace(new RegExp(reg), trans)

    # Pad the message with robot name just incase it was not provided.
    # Only pad if this is a direct chat
    if stanza.attrs.type is 'chat'
      # Following the same name matching pattern as the Robot
      if @robot.alias
        alias = @robot.alias.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&') # escape alias for regexp
        newRegex = new RegExp("^(?:#{@robot.alias}[:,]?|#{@name}[:,]?)", "i")
      else
        newRegex = new RegExp("^#{@name}[:,]?", "i")

      # Prefix message if there is no match
      unless message.match(newRegex)
        message = (@name + " " ) + message

    # Send the message to the robot
    user = @getUser jid
    user.type = stanza.attrs.type

    @receive new TextMessage(user, message)

  handlePresence: (stanza) ->
    jid = new Xmpp.JID(stanza.attrs.from)

    if @isMe(jid)
      return

    if @ignoreUser(jid)
      console.log "Ignoring user presence because of whitelist: #{stanza.attrs.from}"
      console.log "  Accepted Users: " + @options.acceptUsers.join(',')
      console.log "  Accepted Domains: " + @options.acceptDomains.join(',')
      return

    # xmpp doesn't add types for standard available mesages
    # note that upon joining a room, server will send available
    # presences for all members
    # http://xmpp.org/rfcs/rfc3921.html#rfc.section.2.2.1
    stanza.attrs.type ?= 'available'

    switch stanza.attrs.type
      when 'subscribe'
        console.log "#{jid.from()} subscribed to us"

        @client.send new Xmpp.Element('presence',
            from: @client.jid.toString()
            to:   stanza.attrs.from
            id:   stanza.attrs.id
            type: 'subscribed'
        )

      when 'probe'
        @client.send new Xmpp.Element('presence',
            from: @client.jid.toString()
            to:   stanza.attrs.from
            id:   stanza.attrs.id
        )

      when 'chat'
        @client.send new Xmpp.Element('presence',
            to:   "#{stanza.attrs.from}/#{stanza.attrs.to}"
        )

      when 'available'
        user = @getUser jid
        user.online = true

        @receive new EnterMessage(user)

      when 'unavailable'
        user = @getUser jid
        user.online = false

        @receive new LeaveMessage(user)

  getUser: (jid) ->
    user = @userForId jid.from(),
      name: jid.user
      user: jid.user
      domain: jid.domain

    # This can change from request to request
    user.resource = jid.resource
    return user

  isMe: (jid) ->
    return jid.from() == @options.username

  ignoreUser: (jid) ->
    if @options.acceptDomains.length < 1 and @options.acceptUsers.length < 1
      return false

    ignore = true

    if @options.acceptDomains.length > 0
      ignore = false if jid.domain in @options.acceptDomains

    if @options.acceptUsers.length > 0
      ignore = false if jid.from() in @options.acceptUsers

    return ignore

  send: (envelope, strings...) ->
    for str in strings
      message = new Xmpp.Element('message',
          from: @client.jid.toString()
          to: envelope.user.id
          type: if envelope.room then 'groupchat' else envelope.user.type
        ).
        c('body').t(str)
      # Send it off
      @client.send message

  reply: (envelope, strings...) ->
    for str in strings
      @send envelope, "#{str}"

  error: (err) ->
    console.error err

exports.use = (robot) ->
  new Gtalkbot robot
