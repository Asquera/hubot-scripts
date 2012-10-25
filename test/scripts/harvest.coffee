Tests = require "../tests"
assert = require "assert"
helper = Tests.helper()

require "../../src/scripts/harvest"

tests = [
  (msg) -> assert.equal "Thanks, I'll remember your credentials. Have fun with Harvest."
  (msg) -> assert.equal "Your entries for today, faker:"
]
emulated_service = new EmulatedHarvestService
emulated_service.start helper, tests, ->
  helper.receive "helper: remember my harvest account faker@example.org with password ifakeit"
  helper.receive "helper: daily harvest"

class EmulatedHarvestService
  @_day_entry_id: 0

  # Class method for generating unique day_entry IDs.
  @generate_day_id: ->
    @_day_entry_id++

  # Credentials for the one and only user that can be authenticated
  # at this service.
  fake_accounts:
    faker:
      username: "faker@example.org"
      password: "ifakeit"
      day_entries: new Array
    fooler:
      username: "fooler@example.org"
      password: "ifoolyou"
      day_entres: new Array

  # Starts the server. It will be stopped automatically
  # when it runs out of tests.
  start: (helper, tests, callback)->
    
    danger = Tests.danger helper, (req, res, url) =>
      switch url.pathname
        when "/account/who_am_i" then this.who_am_i(req, res)
        when "/daily" then this.daily(req, res)
        when "/daily/add" then this.daily_add(req, res)
        when /\/daily\/timer\/(\d+)/ then this.daily_timer(req, res, parseInt(RegExp.$1))
        else
          res.writeHead 404
    danger.start tests, -> callback()

  # (internal method)
  # /accounts/who_am_i
  who_am_i: (req, res) ->
    if user = this.authenticate(req)
      res.writeHead 200
      res.end "You are #{user.username}."
    else
      res.writeHead 401 # Unauthorized
      res.end "Authentication failed."

  # (internal method)
  # /daily
  daily: (req, res) ->
    if user = this.authenticate(req)
      res.writeHead 200
      res.end JSON.stringify({day_entries: user.day_entries})
    else
      res.writeHead 401
      res.end "Authentication failed."

  # (internal method)
  # /daily/add
  daily_add: (req, res) ->
    if user = this.authenticate(req)
      data = JSON.parse(req.body)
      user.day_entries.push(day_entry:
        id: EmulatedHarvestService.generate_day_id()
        notes: data.notes
        project_id: data.project_id
        task_id: data.task_id
        started_at: new Date)
      res.writeHead 200
      res.end "OK"
    else
      res.writeHead 401
      res.end "Authentication failed."

  # (internal method)
  # /daily/timer/<id>
  daily_timer: (req, res, id) ->
    if user = this.authenticate(req)
      for entry in user.day_entries
        if entry.id == id
          entry.ended_at = new Date
          res.writeHead 200
          res.end JSON.stringify({hours: 1}); # TODO: It would be possible to calulate this from the started_at and ended_at attributes
          return

      res.writeHead 404
      res.end "Entry not found."
    else
      res.writeHead 401
      res.end "Authentication failed."

  # (internal method)
  # Implement the server side of HTTP Basic authentication. If
  # the user successfully authenticated, returns the user object, otherwise
  # returns null (including the case no authorization header was
  # sent at all).
  authenticate: (req) ->
    # Check if we got a syntactically valid header
    if req.headers.authorization? and req.headers.authorization =~ /Basic (.*)/
      # Check if the credentials are in proper format
      buf = new Buffer(Regexp.$1, "base64")
      auth = buf.toString("utf-8")
      if auth =~ /(\w+):(\w+)/
        # Check if user name and password match.
        if RegExp.$1 == fake_acounts.faker.username and RegExp.$2 == fake_accounts.faker.password
          return fake_accounts.faker # SUCESS!
        else if RegExp.$1 == fake_accounts.fooler.username and RegExp.$2 == fake_accounts.fooler.password
          return fake_accounts.fooler # SUCESS!
        else # Invalid credentials format
          return null
      else
        return null
    else # No (valid) authorization header
      return null