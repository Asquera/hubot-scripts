# Description:
#   Allows Hubot to interact with Harvest's (http://harvestapp.com) time-tracking
#   service.
#
# Dependencies:
#   None
# Configuration:
#   HUBOT_HARVEST_SUBDOMAIN
#     The subdomain you access the Harvest service with, e.g.
#     if you have the Harvest URL http://yourcompany.harvestapp.com
#     you should set this to "yourcompany" (without the quotes).
#
# Commands:
#   hubot remember my harvest account <email> with password <password> - Saves your Harvest credentials
#                                                                        to allow Hubot to track time for you
#   hubot forget my harvest account - Deletes your account credentials from Hubot's memory
#   hubot start harvest at <project>/<task>: <notes> - Start a timer for a task at a project
#                                                      (both of which may be abbreviated, Hubot
#                                                      will ask you if your input is ambigious).
#                                                      An existing timer (if any) will be stopped.
#   hubot stop harvest [at <project>/<task>] - Stop the timer the for a task, if any.
#                                              If no project is given, stops the first
#                                              active timer it can find.
#   hubot daily harvest [of <user>] - Hubot responds with your/a specific user's entries for today
#
# Notes:
# All commands and command arguments are case-insenitive. If you work
# on a project "FooBar", hubot will unterstand "foobar" as well. This
# is also true for abbreviations, so if you don't have similary named
# projects, "foob" will do as expected.
# 
# Author:
#   Quintus

unless process.env.HUBOT_HARVEST_SUBDOMAIN
  console.log "Please set HUBOT_HARVEST_SUBDOMAIN in the environment to use the harvest plugin script."

module.exports = (robot) ->

  # Provide facility for saving the account credentials.
  robot.respond /remember my harvest account (.+) with password (.+)/i, (msg) ->
    account = new HarvestAccount msg.match[1], msg.match[2]

    # If the credentials are valid, remember them, otherwise
    # tell the user they are wrong.
    account.test msg, (valid) ->
      if valid
        msg.message.user.harvest_account = account
        msg.reply "Thanks, I'll remember your credentials. Have fun with Harvest."
      else
        msg.reply "Uh-oh -- I just tested your credentials, but they appear to be wrong. Please specify the correct ones."

  # Allows a user to delete his credentials.
  robot.respond /forget my harvest account/i, (msg) ->
    msg.message.user.harvest_account = null
    msg.reply "Okay, I erased your credentials from my memory."

  # Retrieve your or a specific user's timesheet for today.
  robot.respond /daily harvest( of (.+))?/i, (msg) ->
    # Detect the user; if none is passed, assume the sender.
    if msg.match[2]
      user = robot.userForName(msg.match[2])
      unless user
        msg.reply "#{msg.match[2]}? Who's that?"
        return
    else
      user = msg.message.user

    # Check if we know the detected user's credentials.
    unless user.harvest_account
      if user == msg.message.user
        msg.reply "You have to tell me your Harvest credentials first."
      else
        msg.reply "I didn't crack #{user.name}'s Harvest credentials yet, but I'm working on it... Sorry for the inconvenience."
      return

    user.harvest_account.daily msg, (status, body) ->
      if 200 <= status <= 299
        msg.reply "Your entries for today, #{user.name}:"
        for entry in body.day_entries
          if entry.ended_at == ""
            msg.reply "* #{entry.project} (#{entry.client}) → #{entry.task} <#{entry.notes}> [running since #{entry.started_at} (#{entry.hours}h)]"
          else
            msg.reply "* #{entry.project} (#{entry.client}) → #{entry.task} <#{entry.notes}> [#{entry.started_at} - #{entry.ended_at} (#{entry.hours}h)]"
      else
        msg.reply "Request failed with status #{status}."

  # Kick off a new timer, stopping the previously running one, if any.
  robot.respond /start harvest at (.+)\/(.+): (.*)/i, (msg) ->
    user    = msg.message.user
    project = msg.match[1]
    task    = msg.match[2]
    notes   = msg.match[3]

    # Check if we know the detected user's credentials.
    unless user.harvest_account
      msg.reply "You have to tell me your Harvest credentials first."
      return
    
    user.harvest_account.start msg, project, task, notes, (status, body) ->
      if 200 <= status <= 299
        if body.hours_for_previously_running_timer?
          msg.reply "Previously running timer stopped at #{body.hours_for_previously_running_timer}h."
        msg.reply "Started tracking. Back to your work, #{msg.message.user.name}!"
      else
        msg.reply "Request failed with status #{status}."

  # Stops the timer running for a project/task combination,
  # if any. If no combination is given, stops the first
  # active timer available.
  robot.respond /stop harvest( at (.+)\/(.+))?/i, (msg) ->
    user    = msg.message.user
    unless user.harvest_account
      msg.reply "You have to tell me your Harvest credentials first."
      return
    
    if msg.match[1]
      project = msg.match[2]
      task    = msg.match[3]
      user.harvest_account.stop msg, project, task, (status, body) ->
        if 200 <= status <= 299
          msg.reply "Timer stopped (#{body.hours}h)."
        else
          msg.reply "Request failed with status #{status}."
          msg.reply body
    else
      user.harvest_account.stop_first msg, (status, body) ->
        if 200 <= status <= 299
          msg.reply "Timer stopped (#{body.hours}h)."
        else
          msg.reply "Request failed with status #{status}."

# Class managing the Harvest account associated with
# a user. Keeps track of the user's credentials and can
# be used to query the Harvest API on behalf of that user.
#
# The API calls are asynchronous, i.e. the methods executing
# the request immediately return. To process the response,
# you have to attach a callback to the method call, which
# unless documtened otherwise will receive two arguments,
# the first being the response's status code, the second
# one is the response's body as a JavaScript object created
# via `JSON.parse`.
class HarvestAccount

  constructor: (email, password) ->
    @base_url = "https://#{process.env.HUBOT_HARVEST_SUBDOMAIN}.harvestapp.com"
    @email    = email
    @password = password

  # Tests whether the account credentials are valid.
  # If so, the callback gets passed `true`, otherwise
  # it gets passed `false`.
  test: (msg, callback) ->
   this.request(msg).path("account/who_am_i").get() (err, res, body) ->
      if 200 <= res.statusCode <= 299
        callback true
      else
        callback false

  # Issues /daily to the Harvest API.
  daily: (msg, callback) ->
    this.request(msg).path("/daily").get() (err, res, body) ->
      callback res.statusCode, JSON.parse(body)

  # Issues /daily/add to the Harvest API to add a new timer
  # starting from now.
  start: (msg, target_project, target_task, notes, callback) ->
    this.find_project_and_task msg, target_project, target_task, (project, task) =>
      # OK, task and project found. Start the tracker.
      data =
        notes: notes
        project_id: project.id
        task_id: task.id
      this.request(msg).path("/daily/add").post(JSON.stringify(data)) (err, res, body) ->
        callback res.statusCode, JSON.parse(body)

  # Issues /daily/timer/<id> to the Harvest API to stop
  # the timer running at `entry.id`. If that timer isn't
  # running, replys accordingly, otherwise calls the callback
  # when the operation has finished.
  stop_entry: (msg, entry, callback) ->
    if entry.timer_started_at?
      this.request(msg).path("/daily/timer/#{entry.id}").get() (err, res, body) ->
        callback res.statusCode, JSON.parse(body)
    else
      msg.reply "This timer is not running."

  # Issues /daily/timer/<id> to the Harvest API to stop
  # the timer running at <id>, which is determined by
  # looking up the current day_entry for the given
  # project/task combination. If no entry is found (i.e.
  # no timer has been started for this combination today),
  # replies with an error message and doesn't executes the
  # callback.
  stop: (msg, target_project, target_task, callback) ->
    this.find_day_entry msg, target_project, target_task, (entry) =>
      this.stop_entry msg, entry, (status, body) -> callback status, body

  # Issues /daily/timer/<id> to the Harvest API to stop
  # the timer running at <id>, which is the first active
  # timer it can find in today's timesheet, then calls the
  # callback. If no active timer is found, replies accordingly
  # and doesn't execute the callback.
  stop_first: (msg, callback) ->
    this.daily msg, (status, body) =>
      found_entry = null
      for entry in body.day_entries
        if entry.timer_started_at?
          found_entry = entry
          break

      if found_entry?
        this.stop_entry msg, found_entry, (status, body) -> callback status, body
      else
        msg.reply "Currently there is no timer running."

  # (internal method)
  # Assembles the basic parts of a request to the Harvest
  # API, i.e. the Content-Type/Accept and authorization
  # headers. The returned HTTPClient object can (and should)
  # be customized further by calling path() and other methods
  # on it.
  request: (msg) ->
    req = msg.http(@base_url).headers
      "Content-Type": "application/json"
      "Accept": "application/json"
    .auth(@email, @password)
    return req

  # (internal method)
  # Searches through all projects available to the sender of
  # `msg` for a project whose name inclues `target_project`.
  # If exactly one is found, query all tasks available for the
  # sender in this projects, and if exactly one is found,
  # execute the callback with the project object as the first
  # and the task object as the second argument. If more or
  # less than one project or task are found to match the query,
  # reply accordingly to the user (the callback never gets
  # executed in this case).
  find_project_and_task: (msg, target_project, target_task, callback) ->
    this.daily msg, (status, body) ->
      # Search through all possible projects for the matching ones
      projects = []
      for project in body.projects
        if project.name.toLowerCase().indexOf(target_project.toLowerCase()) != -1
          projects.push(project)
      # Ask the user if the project name is ambivalent
      if projects.length == 0
        msg.reply "Sorry, no matching projects found."
        return
      else if projects.length > 1
        msg.reply "I found the following #{projects.length} projects for your query, please be more precise:"
        for project in projects
          msg.reply "* #{project.name}"
        return

      # Repeat the same process for the tasks
      tasks = []
      for task in projects[0].tasks
        if task.name.toLowerCase().indexOf(target_task.toLowerCase()) != -1
          tasks.push(task)
      if tasks.length == 0
        msg.reply "Sorry, no matching tasks found."
      else if tasks.length > 1
        msg.reply "I found the following #{tasks.length} tasks for your query, please be more pricese:"
        for task in tasks
          msg.reply "* #{task.name}"
        return

      # Execute the callback with the results
      callback projects[0], tasks[0]

  # (internal method)
  # Searches through all entries made for today and tries
  # to find a running timer for the given project/task
  # combination.
  # If it is found, the respective entry object is passed to
  # the callback, otherwise an error message is replied and
  # the callback doesn't get executed.
  find_day_entry: (msg, target_project, target_task, callback) ->
    this.find_project_and_task msg, target_project, target_task, (project, task) =>
      this.daily msg, (status, body) ->
        # For some unknown reason, the daily entry IDs are strings
        # instead of numbers, causing the comparison below to fail.
        # So, convert our target stuff to strings as well.
        project_id = "#{project.id}"
        task_id    = "#{task.id}"
        # Iterate through all available entries for today
        # and try to find the requested ID.
        found_entry = null
        for entry in body.day_entries
          if entry.project_id == project_id and entry.task_id == task_id and entry.timer_started_at?
            found_entry = entry
            break

        # None found
        unless found_entry?
          msg.reply "I couldn't find a running timer in today's timesheet for the combination #{target_project}/#{target_task}."
          return

        # Execute the callback with the result
        callback found_entry
